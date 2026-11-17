/*++

Copyright (c) Microsoft Corporation All Rights Reserved

Module Name:

    endpoints.h

Abstract:

    Node and Pin numbers and other common definitions for simple audio sample.
--*/

#ifndef _SIMPLEAUDIOSAMPLE_ENDPOINTS_H_
#define _SIMPLEAUDIOSAMPLE_ENDPOINTS_H_

//----------------------------------------------------
// New defines for the render endpoints.
//----------------------------------------------------

// Default pin instances.
#define MAX_INPUT_SYSTEM_STREAMS        1

// Wave pins - no mix, no offload
enum 
{
    KSPIN_WAVE_RENDER3_SINK_SYSTEM = 0, 
    KSPIN_WAVE_RENDER3_SOURCE
};

// Wave pins - offloading is NOT supported.
enum 
{
    KSPIN_WAVE_RENDER2_SINK_SYSTEM = 0, 
    KSPIN_WAVE_RENDER2_SINK_LOOPBACK, 
    KSPIN_WAVE_RENDER2_SOURCE
};

// Topology pins.
enum
{
    KSPIN_TOPO_WAVEOUT_SOURCE = 0,
    KSPIN_TOPO_LINEOUT_DEST,
};

//----------------------------------------------------
// New defines for the capture endpoints.
//----------------------------------------------------

// Wave pins
enum 
{
    KSPIN_WAVE_BRIDGE = 0,
    KSPIN_WAVEIN_HOST,
};

// data format attribute range definitions.
static
KSATTRIBUTE PinDataRangeSignalProcessingModeAttribute =
{
    sizeof(KSATTRIBUTE),
    0,
    STATICGUIDOF(KSATTRIBUTEID_AUDIOSIGNALPROCESSING_MODE),
};

static
PKSATTRIBUTE PinDataRangeAttributes[] =
{
    &PinDataRangeSignalProcessingModeAttribute,
};

static
KSATTRIBUTE_LIST PinDataRangeAttributeList =
{
    ARRAYSIZE(PinDataRangeAttributes),
    PinDataRangeAttributes,
};

// Windows 11 24H2 queries loopback tap-point capabilities and supplies this
// attribute at pin creation. This driver implements pre-volume/mute only.
static
KSATTRIBUTE PinLoopbackTapPointAttribute =
{
    sizeof(KSATTRIBUTE),
    0,
    STATICGUIDOF(KSATTRIBUTEID_AUDIOLOOPBACK_TAPPOINT),
};

static
PKSATTRIBUTE PinLoopbackDataRangeAttributes[] =
{
    &PinLoopbackTapPointAttribute,
};

static
KSATTRIBUTE_LIST PinLoopbackDataRangeAttributeList =
{
    ARRAYSIZE(PinLoopbackDataRangeAttributes),
    PinLoopbackDataRangeAttributes,
};

#endif // _SIMPLEAUDIOSAMPLE_ENDPOINTS_H_
