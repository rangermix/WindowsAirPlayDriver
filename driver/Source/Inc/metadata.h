/*
 * WinAirPlayAudio software-device metadata contract.
 *
 * This file is original WinAirPlayAudio code. The surrounding PortCls/WaveRT
 * implementation is derived from the Microsoft Windows Driver Samples at
 * commit 2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89.
 */

#pragma once

#include <devpropdef.h>

// {54B65A8E-7CD3-4F7B-953B-59A21C2E5CDD}
//
// The service supplies these as initial SwDevice properties. Keeping them in
// the initial SwDeviceCreate property array makes their values persistent
// across a handle-lifetime unplug/replug of the same software-device instance.
DEFINE_DEVPROPKEY(
    DEVPKEY_WinAirPlayAudio_ReceiverId,
    0x54b65a8e, 0x7cd3, 0x4f7b, 0x95, 0x3b, 0x59, 0xa2, 0x1c, 0x2e, 0x5c, 0xdd,
    2);

DEFINE_DEVPROPKEY(
    DEVPKEY_WinAirPlayAudio_ReceiverDisplayName,
    0x54b65a8e, 0x7cd3, 0x4f7b, 0x95, 0x3b, 0x59, 0xa2, 0x1c, 0x2e, 0x5c, 0xdd,
    3);

#define WINAIRPLAYAUDIO_FRIENDLY_NAME_MAX_CHARS 256
#define WINAIRPLAYAUDIO_RECEIVER_ID_CHARS 13
#define WINAIRPLAYAUDIO_FALLBACK_FRIENDLY_NAME L"WinAirPlayAudio Receiver"
