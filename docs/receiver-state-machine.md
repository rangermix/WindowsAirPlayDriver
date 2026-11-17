# Receiver state machine

The registry owns product state. DNS-SD backends emit observations; they never create endpoints or start sockets directly.

```text
Discovered
  -> Resolving
  -> OnlineUnsupported --------------------------+
  -> OnlineSupported                             |
       -> EndpointCreating                       |
       -> EndpointReady                          |
            -> Connecting                        |
            -> Streaming                         |
                 -> Recovering -> Connecting     |
                                                  |
any online state -> GraceOffline -- re-add ------+
                         |
                         +-- grace expires -> Removing -> Removed
```

## Observation model

An observation is keyed by `(service type, normalized service full name, interface ID)`. It contains bounded TXT data, hostname, port, and scoped IPv4/IPv6 addresses. Last-seen and grace-deadline values belong to the receiver record. The browser additionally keeps a bounded freshness counter for each service key; this prevents a refreshed companion `_airplay` record from keeping a disappeared `_raop` transport alive.

A resolved event atomically replaces the complete interface snapshot for one DNS-SD service, so an omitted interface removes only that interface observation. In contrast, `mdns-sd` exposes `ServiceRemoved` at service granularity; that event removes every observation for the named service. Loss of the last usable `_raop` service enters receiver grace even when companion `_airplay` metadata remains. The registry has a tested interface-specific removal primitive, but live multi-homed backend semantics remain **NOT RUN**.

The process keeps the long-lived primary `_raop` and `_airplay` browsers and starts a separate bounded query pulse on the configured cadence. Both primary and pulse resolutions go through the same parser and registry path. A genuine `ServiceRemoved` received by either browser is authoritative: the pinned backend emits `SearchStopped`, not a synthetic removal, when an auxiliary browse is stopped.

Silent loss is handled conservatively. Only a pulse in which both service searches started, completed their 1.5-second response window, and acknowledged `SearchStopped` counts as negative evidence. Three consecutive successful pulse epochs that omit one exact service key expire that service through the normal grace path. A failed start, stop, acknowledgement, or daemon shutdown does not age any receiver. A missing stop acknowledgement has a one-second deadline; the auxiliary daemon is then retired so a stuck pulse cannot suppress all future refreshes.

Receiver identity comes from a normalized advertised RAOP device identifier. IP address, hostname, display name, and endpoint ID are never identity inputs. Missing, malformed, conflicting, or changing identifiers are rejected or quarantined; no unstable fallback identity can produce a functional endpoint. The canonical identifier is lifecycle-stable, not cryptographically authenticated.

## Capability gate

After resolution, the capability classifier selects a named supported RAOP profile or an exact unsupported reason. `_airplay._tcp` enriches metadata but never establishes transport support. `OnlineUnsupported` receivers create no misleading render endpoint.

## Timers

Runtime bounds/defaults are owned by `ServiceConfig`; the discovery-to-endpoint
figure is an acceptance target:

- normal discovery-to-endpoint target: 5 seconds;
- active-query cadence: 4 seconds by default, configurable from 1 to 60 seconds;
- active-query response window: 1.5 seconds;
- silent-loss threshold: 3 successful missed query epochs, followed by normal grace;
- active-query stop acknowledgement: 1 second, then daemon reset;
- offline grace: 8 seconds;
- initial reconnect delay: 250 ms;
- reconnect cap: 30 seconds;
- idle disconnect: 5 seconds.

The query cadence, offline grace, reconnect, idle, parser, queue, and endpoint-create bounds are centralized in `ServiceConfig`. The normal five-second discovery target is an acceptance target rather than an artificial DNS timeout. A silent disappearance necessarily takes longer because three complete query epochs plus the grace period are required; explicit DNS-SD removal can enter grace immediately.

## Required transition behavior

- A resolved add/update replaces the matching service snapshot and cancels `GraceOffline`.
- Each successful active-query epoch refreshes or ages exact RAOP/AirPlay service keys independently. Failed epochs do not count as absence.
- An address change updates the deterministic, scope-preserving transport-candidate list without changing identity/container. Retryable connection failures rotate through that list. Authentication or incompatible-profile rejection removes the endpoint and blocks that exact target fingerprint, so identical discovery refreshes cannot recreate a misleading endpoint; a later reconciliation with changed addresses, profile, or protected credential may try again. The credential tool's documented service restart triggers immediate credential reconciliation.
- A resolved snapshot that omits one of several interfaces preserves the endpoint while another usable observation remains. The backend's high-level service-removal event is deliberately not represented as an interface-specific removal.
- The final observation removal enters grace; it does not immediately close the software-device handle.
- Reappearance during grace returns to the preceding online/ready state with the same handle.
- Grace expiry first stops capture/sender, then closes the software-device handle.
- Service start reconstructs state only from live observations; default `HSWDEVICE` lifetime prevents old-process handles from keeping endpoints present.
- Shutdown cancels discovery, drains/joins workers, closes senders, and closes all device handles.

Invalid transitions return a contextual error and are test failures. State callbacks are serialized through the registry event loop; objects are not mutated concurrently by raw DNS-SD callbacks.

The discovery registry currently persists the externally consequential online/unsupported/grace/removing/removed states. Endpoint creation, capture connection, streaming, and recovery are owned by service worker state and structured events rather than written back into the discovery snapshot. A unified externally queryable state projection remains a post-install improvement.
