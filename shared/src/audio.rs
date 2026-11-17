//! Deterministic audio generation, conversion, and resampling.

use std::f64::consts::TAU;

use thiserror::Error;

/// Maximum channel count accepted by the user-mode conversion path.
pub const MAX_CHANNELS: u16 = 2;

/// An interleaved PCM format.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AudioFormat {
    /// Frames per second.
    pub sample_rate: u32,
    /// Number of interleaved channels.
    pub channels: u16,
}

impl AudioFormat {
    /// Validates that this format can be converted by the MVP pipeline.
    pub fn validate(self) -> Result<Self, AudioError> {
        if self.sample_rate == 0 {
            return Err(AudioError::InvalidSampleRate(self.sample_rate));
        }
        if !(1..=MAX_CHANNELS).contains(&self.channels) {
            return Err(AudioError::UnsupportedChannelCount(self.channels));
        }
        Ok(self)
    }

    fn channels_usize(self) -> usize {
        usize::from(self.channels)
    }
}

/// Errors returned by audio generation and conversion.
#[derive(Debug, Error, PartialEq)]
pub enum AudioError {
    /// A zero sample rate cannot describe audio.
    #[error("audio conversion: sample rate must be non-zero, got {0}")]
    InvalidSampleRate(u32),
    /// The MVP conversion path supports mono and stereo only.
    #[error("audio conversion: channel count {0} is unsupported; expected mono or stereo")]
    UnsupportedChannelCount(u16),
    /// Interleaved input ended in the middle of a frame.
    #[error(
        "audio conversion: {sample_count} samples do not contain whole {channels}-channel frames"
    )]
    IncompleteFrame {
        /// Number of input samples.
        sample_count: usize,
        /// Number of channels in each frame.
        channels: u16,
    },
    /// A sine-wave parameter was invalid.
    #[error("audio generator: {parameter} must be {requirement}, got {value}")]
    InvalidToneParameter {
        /// Parameter name.
        parameter: &'static str,
        /// Human-readable constraint.
        requirement: &'static str,
        /// Supplied value.
        value: f64,
    },
    /// Processing was attempted after the finite resampler was finalized.
    #[error("audio resampler: stream was finalized; reset it before supplying more audio")]
    ResamplerFinalized,
    /// A frame counter exceeded its representable range.
    #[error("audio conversion: frame counter overflow")]
    FrameCounterOverflow,
}

/// An output chunk with an absolute frame position.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConvertedChunk {
    /// Interleaved signed 16-bit samples.
    pub samples: Vec<i16>,
    /// Absolute output-frame position of the first sample frame.
    pub start_frame: u64,
    /// Whether the input source reported a discontinuity before this chunk.
    pub discontinuity: bool,
}

impl ConvertedChunk {
    /// Returns the number of interleaved frames in this chunk.
    #[must_use]
    pub fn frame_count(&self, channels: u16) -> usize {
        self.samples.len() / usize::from(channels)
    }
}

/// Converts a normalized float sample to signed 16-bit PCM with clipping.
#[must_use]
#[allow(clippy::cast_possible_truncation)]
pub fn f32_to_i16(sample: f32) -> i16 {
    if sample.is_nan() {
        return 0;
    }
    if sample <= -1.0 {
        return i16::MIN;
    }
    if sample >= 1.0 {
        return i16::MAX;
    }
    let scale = if sample.is_sign_negative() {
        32_768.0
    } else {
        f32::from(i16::MAX)
    };
    (sample * scale).round() as i16
}

/// Converts signed 16-bit PCM to a normalized float sample.
#[must_use]
pub fn i16_to_f32(sample: i16) -> f32 {
    if sample.is_negative() {
        f32::from(sample) / 32_768.0
    } else {
        f32::from(sample) / f32::from(i16::MAX)
    }
}

/// Stateful channel conversion and linear resampling.
///
/// The resampler uses an integer phase accumulator. Consequently, chunking does
/// not change output positions and long-running 44.1/48 kHz conversion cannot
/// accumulate floating-point timestamp drift.
#[derive(Debug)]
pub struct AudioConverter {
    input: AudioFormat,
    output: AudioFormat,
    resampler: LinearResampler,
    next_output_frame: u64,
}

impl AudioConverter {
    /// Creates a converter for mono/stereo float or signed 16-bit PCM.
    pub fn new(input: AudioFormat, output: AudioFormat) -> Result<Self, AudioError> {
        let input = input.validate()?;
        let output = output.validate()?;
        Ok(Self {
            input,
            output,
            resampler: LinearResampler::new(input.sample_rate, output.sample_rate, output.channels),
            next_output_frame: 0,
        })
    }

    /// Converts interleaved normalized floating-point samples.
    pub fn process_f32(
        &mut self,
        input: &[f32],
        discontinuity: bool,
    ) -> Result<ConvertedChunk, AudioError> {
        validate_complete_frames(input.len(), self.input.channels)?;
        if discontinuity {
            self.resampler.reset();
        }

        let channel_converted = convert_channels(input, self.input.channels, self.output.channels);
        let output = self.resampler.process(&channel_converted)?;
        self.make_chunk(output, discontinuity)
    }

    /// Converts interleaved signed 16-bit samples.
    pub fn process_i16(
        &mut self,
        input: &[i16],
        discontinuity: bool,
    ) -> Result<ConvertedChunk, AudioError> {
        validate_complete_frames(input.len(), self.input.channels)?;
        let float_input: Vec<f32> = input.iter().copied().map(i16_to_f32).collect();
        self.process_f32(&float_input, discontinuity)
    }

    /// Finalizes a finite stream, holding its last sample for the final
    /// fractional interpolation interval.
    pub fn finish(&mut self) -> Result<ConvertedChunk, AudioError> {
        let output = self.resampler.finish()?;
        self.make_chunk(output, false)
    }

    /// Returns the next absolute output-frame position.
    #[must_use]
    pub const fn next_output_frame(&self) -> u64 {
        self.next_output_frame
    }

    fn make_chunk(
        &mut self,
        output: Vec<f32>,
        discontinuity: bool,
    ) -> Result<ConvertedChunk, AudioError> {
        let frame_count = output.len() / self.output.channels_usize();
        let frame_count =
            u64::try_from(frame_count).map_err(|_| AudioError::FrameCounterOverflow)?;
        let start_frame = self.next_output_frame;
        self.next_output_frame = self
            .next_output_frame
            .checked_add(frame_count)
            .ok_or(AudioError::FrameCounterOverflow)?;
        Ok(ConvertedChunk {
            samples: output.into_iter().map(f32_to_i16).collect(),
            start_frame,
            discontinuity,
        })
    }
}

#[derive(Debug)]
struct LinearResampler {
    input_rate: u32,
    output_rate: u32,
    channels: usize,
    next_output_numerator: u128,
    total_input_frames: u64,
    previous_frame: Option<Vec<f32>>,
    finalized: bool,
}

impl LinearResampler {
    fn new(input_rate: u32, output_rate: u32, channels: u16) -> Self {
        Self {
            input_rate,
            output_rate,
            channels: usize::from(channels),
            next_output_numerator: 0,
            total_input_frames: 0,
            previous_frame: None,
            finalized: false,
        }
    }

    #[allow(clippy::cast_possible_truncation)]
    fn process(&mut self, input: &[f32]) -> Result<Vec<f32>, AudioError> {
        if self.finalized {
            return Err(AudioError::ResamplerFinalized);
        }
        debug_assert_eq!(input.len() % self.channels, 0);
        let frame_count = input.len() / self.channels;
        if frame_count == 0 {
            return Ok(Vec::new());
        }

        let chunk_start = self.total_input_frames;
        let chunk_frames =
            u64::try_from(frame_count).map_err(|_| AudioError::FrameCounterOverflow)?;
        let chunk_end = chunk_start
            .checked_add(chunk_frames)
            .ok_or(AudioError::FrameCounterOverflow)?;
        let mut output = Vec::with_capacity(
            frame_count.saturating_mul(usize::try_from(self.output_rate).unwrap_or(usize::MAX))
                / usize::try_from(self.input_rate).unwrap_or(usize::MAX)
                * self.channels
                + self.channels,
        );

        loop {
            let base_u128 = self.next_output_numerator / u128::from(self.output_rate);
            let remainder = self.next_output_numerator % u128::from(self.output_rate);
            let Ok(base) = u64::try_from(base_u128) else {
                return Err(AudioError::FrameCounterOverflow);
            };
            if base >= chunk_end {
                break;
            }
            let next = base
                .checked_add(u64::from(remainder != 0))
                .ok_or(AudioError::FrameCounterOverflow)?;
            if next >= chunk_end {
                break;
            }

            let remainder = u32::try_from(remainder).expect("remainder is below output rate");
            let fraction = f64::from(remainder) / f64::from(self.output_rate);
            for channel in 0..self.channels {
                let left = f64::from(self.sample_at(input, chunk_start, base, channel));
                let right = f64::from(self.sample_at(input, chunk_start, next, channel));
                output.push((left + (right - left) * fraction) as f32);
            }
            self.next_output_numerator = self
                .next_output_numerator
                .checked_add(u128::from(self.input_rate))
                .ok_or(AudioError::FrameCounterOverflow)?;
        }

        let final_frame_offset = (frame_count - 1) * self.channels;
        self.previous_frame =
            Some(input[final_frame_offset..final_frame_offset + self.channels].to_vec());
        self.total_input_frames = chunk_end;
        Ok(output)
    }

    fn finish(&mut self) -> Result<Vec<f32>, AudioError> {
        if self.finalized {
            return Err(AudioError::ResamplerFinalized);
        }
        self.finalized = true;
        let Some(last_frame) = self.previous_frame.as_ref() else {
            return Ok(Vec::new());
        };

        let mut output = Vec::new();
        loop {
            let base_u128 = self.next_output_numerator / u128::from(self.output_rate);
            let base = u64::try_from(base_u128).map_err(|_| AudioError::FrameCounterOverflow)?;
            if base >= self.total_input_frames {
                break;
            }
            output.extend_from_slice(last_frame);
            self.next_output_numerator = self
                .next_output_numerator
                .checked_add(u128::from(self.input_rate))
                .ok_or(AudioError::FrameCounterOverflow)?;
        }
        Ok(output)
    }

    fn reset(&mut self) {
        self.next_output_numerator = 0;
        self.total_input_frames = 0;
        self.previous_frame = None;
        self.finalized = false;
    }

    fn sample_at(&self, current: &[f32], chunk_start: u64, frame: u64, channel: usize) -> f32 {
        if frame < chunk_start {
            return self.previous_frame.as_ref().expect("previous frame")[channel];
        }
        let offset = usize::try_from(frame - chunk_start).expect("frame fits usize");
        current[offset * self.channels + channel]
    }
}

fn validate_complete_frames(sample_count: usize, channels: u16) -> Result<(), AudioError> {
    if sample_count.is_multiple_of(usize::from(channels)) {
        Ok(())
    } else {
        Err(AudioError::IncompleteFrame {
            sample_count,
            channels,
        })
    }
}

fn convert_channels(input: &[f32], input_channels: u16, output_channels: u16) -> Vec<f32> {
    match (input_channels, output_channels) {
        (1, 1) | (2, 2) => input.to_vec(),
        (1, 2) => input.iter().flat_map(|sample| [*sample, *sample]).collect(),
        (2, 1) => input
            .chunks_exact(2)
            .map(|frame| (frame[0] + frame[1]) * 0.5)
            .collect(),
        _ => unreachable!("formats were validated"),
    }
}

/// A deterministic, phase-continuous sine-wave source.
#[derive(Clone, Debug)]
pub struct SineGenerator {
    format: AudioFormat,
    frequency_hz: f64,
    amplitude: f32,
    next_frame: u64,
}

impl SineGenerator {
    /// Creates a deterministic sine source.
    pub fn new(format: AudioFormat, frequency_hz: f64, amplitude: f32) -> Result<Self, AudioError> {
        let format = format.validate()?;
        if !frequency_hz.is_finite()
            || frequency_hz <= 0.0
            || frequency_hz >= f64::from(format.sample_rate) / 2.0
        {
            return Err(AudioError::InvalidToneParameter {
                parameter: "frequency",
                requirement: "finite, positive, and below Nyquist",
                value: frequency_hz,
            });
        }
        if !amplitude.is_finite() || !(0.0..=1.0).contains(&amplitude) {
            return Err(AudioError::InvalidToneParameter {
                parameter: "amplitude",
                requirement: "finite and between 0 and 1",
                value: f64::from(amplitude),
            });
        }
        Ok(Self {
            format,
            frequency_hz,
            amplitude,
            next_frame: 0,
        })
    }

    /// Renders the requested number of frames as interleaved normalized floats.
    #[must_use]
    #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
    pub fn render(&mut self, frames: usize) -> Vec<f32> {
        let mut output = Vec::with_capacity(frames * self.format.channels_usize());
        for offset in 0..frames {
            let frame = self.next_frame + u64::try_from(offset).expect("offset fits u64");
            let phase = TAU * self.frequency_hz * frame as f64 / f64::from(self.format.sample_rate);
            let sample = (phase.sin() as f32) * self.amplitude;
            output.extend(std::iter::repeat_n(sample, self.format.channels_usize()));
        }
        self.next_frame = self
            .next_frame
            .wrapping_add(u64::try_from(frames).expect("frame count fits u64"));
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mono_is_duplicated_to_stereo() {
        let mut converter = AudioConverter::new(
            AudioFormat {
                sample_rate: 44_100,
                channels: 1,
            },
            AudioFormat {
                sample_rate: 44_100,
                channels: 2,
            },
        )
        .unwrap();
        let chunk = converter.process_f32(&[0.25, -0.5], false).unwrap();
        assert_eq!(
            chunk.samples,
            vec![
                f32_to_i16(0.25),
                f32_to_i16(0.25),
                f32_to_i16(-0.5),
                f32_to_i16(-0.5)
            ]
        );
    }

    #[test]
    fn stereo_is_preserved() {
        let mut converter = AudioConverter::new(
            AudioFormat {
                sample_rate: 44_100,
                channels: 2,
            },
            AudioFormat {
                sample_rate: 44_100,
                channels: 2,
            },
        )
        .unwrap();
        let samples = [i16::MIN, i16::MAX, -32_767, 0, 1, -2, 3, -4];
        let chunk = converter.process_i16(&samples, false).unwrap();
        assert_eq!(chunk.samples, samples);
    }

    #[test]
    fn float_conversion_clips_and_maps_silence() {
        assert_eq!(f32_to_i16(-2.0), i16::MIN);
        assert_eq!(f32_to_i16(-1.0), i16::MIN);
        assert_eq!(f32_to_i16(0.0), 0);
        assert_eq!(f32_to_i16(1.0), i16::MAX);
        assert_eq!(f32_to_i16(2.0), i16::MAX);
        assert_eq!(f32_to_i16(f32::NAN), 0);
        assert!((i16_to_f32(i16::MIN) + 1.0).abs() < f32::EPSILON);
    }

    #[test]
    #[allow(clippy::cast_possible_truncation)]
    fn chunking_does_not_change_resampling_output() {
        let input_format = AudioFormat {
            sample_rate: 48_000,
            channels: 1,
        };
        let output_format = AudioFormat {
            sample_rate: 44_100,
            channels: 1,
        };
        let input: Vec<f32> = (0..4_800)
            .map(|index| ((f64::from(index) * 0.01).sin()) as f32)
            .collect();

        let mut whole = AudioConverter::new(input_format, output_format).unwrap();
        let mut whole_samples = whole.process_f32(&input, false).unwrap().samples;
        whole_samples.extend(whole.finish().unwrap().samples);

        let mut chunked = AudioConverter::new(input_format, output_format).unwrap();
        let mut chunked_samples = Vec::new();
        for part in input.chunks(137) {
            chunked_samples.extend(chunked.process_f32(part, false).unwrap().samples);
        }
        chunked_samples.extend(chunked.finish().unwrap().samples);
        assert_eq!(chunked_samples, whole_samples);
        assert_eq!(chunked_samples.len(), 4_410);
    }

    #[test]
    fn resampling_has_bounded_long_duration_frame_drift() {
        let mut converter = AudioConverter::new(
            AudioFormat {
                sample_rate: 48_000,
                channels: 2,
            },
            AudioFormat {
                sample_rate: 44_100,
                channels: 2,
            },
        )
        .unwrap();
        let input = vec![0.0; 2 * 997];
        let mut remaining = 480_000;
        let mut frames = 0;
        while remaining != 0 {
            let this_time = remaining.min(997);
            frames += converter
                .process_f32(&input[..this_time * 2], false)
                .unwrap()
                .frame_count(2);
            remaining -= this_time;
        }
        frames += converter.finish().unwrap().frame_count(2);
        assert_eq!(frames, 441_000);
    }

    #[test]
    fn timestamps_are_contiguous_and_discontinuity_is_explicit() {
        let format = AudioFormat {
            sample_rate: 44_100,
            channels: 2,
        };
        let mut converter = AudioConverter::new(format, format).unwrap();
        let first = converter.process_f32(&[0.0; 20], false).unwrap();
        let second = converter.process_f32(&[0.0; 12], true).unwrap();
        assert_eq!(first.start_frame, 0);
        assert_eq!(second.start_frame, 10);
        assert!(second.discontinuity);
        assert_eq!(converter.next_output_frame(), 16);
    }

    #[test]
    fn partial_interleaved_frame_is_rejected_without_advancing_timestamp() {
        let format = AudioFormat {
            sample_rate: 44_100,
            channels: 2,
        };
        let mut converter = AudioConverter::new(format, format).unwrap();
        assert!(matches!(
            converter.process_f32(&[0.0], false),
            Err(AudioError::IncompleteFrame { .. })
        ));
        assert_eq!(converter.next_output_frame(), 0);
    }

    #[test]
    fn sine_generation_is_phase_continuous_across_chunks() {
        let format = AudioFormat {
            sample_rate: 44_100,
            channels: 2,
        };
        let mut whole = SineGenerator::new(format, 997.0, 0.5).unwrap();
        let expected = whole.render(1_000);
        let mut chunked = SineGenerator::new(format, 997.0, 0.5).unwrap();
        let mut actual = chunked.render(127);
        actual.extend(chunked.render(873));
        assert_eq!(actual, expected);
    }
}
