# Audio pipeline

## Capture contract

For each ready endpoint, the service activates the exact `IMMDevice` by its deterministic container ID. The private receiver-ID property is an optional consistency check: an absent property is allowed because AudioEndpointBuilder does not project arbitrary KS-interface properties reliably, while a present mismatch, malformed value, or unreadable value fails closed. It configures `IAudioClient2` for:

- shared mode;
- loopback;
- event callback;
- `AUDCLNT_STREAMOPTIONS_NONE` on the Windows 11 24H2+ target.

The service intentionally does not call `IAudioClient2::SetClientProperties`. A live initialization matrix showed that default client properties support shared event-driven loopback, while setting `AudioCategory_Media` makes the same `IAudioClient::Initialize` call fail with `E_INVALIDARG`, including on a physical render endpoint. The driver exposes one explicit rendered-mix loopback pin, implements `KSPROPERTY_AUDIOLOOPBACK_TAPPOINT_CAPS`, and advertises only the required pre-volume/mute capability. The captured samples therefore must not be described as post-volume; an additional control path is required before Windows endpoint volume/mute can be claimed to affect receiver playback. The endpoint mix format and buffer size are read before streaming. The service does not assume float/48 kHz: it copies the reported format into an explicit `CaptureFormat` and rejects zero or overflowing fields.

## Bounded handoff

The capture queue allocates a fixed number of equal-sized slots before `IAudioClient::Start`. Each slot is large enough for the endpoint's reported shared buffer. On every event, the capture worker drains all available packets and:

1. attempts a non-blocking queue lock;
2. reuses a preallocated free slot;
3. copies the packet or fills explicit silence;
4. records frame count, WASAPI flags, device position, and QPC position;
5. publishes the slot.

It performs no DNS, network I/O, codec initialization, logging, or heap allocation in this drain path.

If no slot is available, the oldest queued packet is replaced and the earliest
surviving packet is marked discontinuous. If the consumer holds every slot or
the lock is contended, the new packet is dropped and the next later accepted
packet is marked. Repeated losses coalesce at the correct gap boundary. Native
`DATA_DISCONTINUITY` is preserved; `TIMESTAMP_ERROR` invalidates only the QPC
position and does not invent an audio gap. Downstream resets resampler history,
drops any partial local RTP packet, marks the first surviving RTP packet, and
emits an immediate capture-time `0x90` sync without sending RTSP `FLUSH`.
Explicit remote flush remains a separate operation. There is no startup
`FLUSH`.

## Conversion

Conversion is a separate worker:

- decode the declared Windows sample representation;
- preserve stereo or duplicate mono into stereo;
- clamp float before signed 16-bit conversion;
- preserve explicit silence;
- maintain partial-frame remainder safely;
- resample 44.1 or 48 kHz input to the selected receiver rate using persistent phase/history;
- propagate capture discontinuity by resetting resampler history and RAOP timestamp policy.

Integer frame/timestamp arithmetic is checked. RTP timestamp advancement derives from output frames, not wall-clock callback count.

## Packet and network workers

The same non-real-time worker converts each leased capture packet and packetizes
raw stereo signed 16-bit network-byte-order `L16/44100/2`. RTSP and every UDP
socket bind to the local address associated with the selected DNS-SD interface,
rather than trusting the system default route. The first packet's WASAPI QPC
time anchors RTP pacing and sync NTP time across synchronous RTSP setup, so the
setup backlog is caught up rather than retained for the session. Sync NTP is
derived from the current monotonic/wall-clock pair, keeping it in the same live
clock domain as timing responses. Audio older than the effective sync-latency
budget is discarded and the next packet is marked rather than allowing stale
latency to accumulate. The UDP sockets remain nonblocking. If an RTP send meets
transient socket backpressure, the worker retains and retries the exact
packetized datagram at one-millisecond intervals while servicing timing and
retransmission traffic. The retry deadline is the lesser of the configured I/O
timeout and that packet's remaining capture-time playout budget. Packetizer
state, pacing, statistics, and retransmission history commit only after a full
UDP datagram send. There is no unbounded intermediate queue. A separate
fixed-size retransmission history retains only the configured recent sequence
window. Network timeouts, timing responses, resend requests, RTSP state, and
DPAPI access never run in the WASAPI drain path.

Receiver-initiated timing requires the exact installer-owned inbound UDP rule;
its full scope and trust contract are in [security](security.md#firewall-and-listeners).

## Silence, idle, and recovery

WASAPI's silent flag produces actual zeroed frames; a null non-silent buffer is a discontinuity/error. Sustained silence does not masquerade as a disconnected capture. The session idles after the central `idle_disconnect` timeout and closes cleanly. New audio resumes through an explicit connect/setup state. Normal idle/cancellation closure finishes a partial packet before `TEARDOWN`; a terminal media-send failure skips that finish step so it cannot emit audio after a missing RTP datagram, then still tears down and drops the session.

The [driver contract](driver-design.md#audio-path) owns producer-driven ring
progress, protected-content gates and discontinuities when retained audio is
overrun. The service never treats synthetic capture progress as rendered audio.

Device invalidation closes the queue with a reason and waits for endpoint reconciliation. The intended bounded teardown remains subject to the RTSP deadline/cancellation gap in [DEF-002](DEFECTS.md#def-002--absolute-rtsp-deadlines-and-cancellation). Network failure uses bounded exponential backoff with jitter and enters `Recovering`; buffered latency is never allowed to grow without bound.

## Measurements

Structured JSONL logs record endpoint-arrival/session-start time, configured and
effective sync offsets, startup backlog, capture packet-loss details, local
timeline recoveries, audio frames/packets, resend requests/hits/misses, timing
responses, and sync packets. The diagnostic tool returns a bounded log tail.
Current versus historical installed results are recorded once in
[VALIDATION.md](../VALIDATION.md). Physical output, endpoint controls, adaptive
clock correction, latency/CPU/memory and installed soak acceptance remain open
in [DEFECTS.md](DEFECTS.md).
