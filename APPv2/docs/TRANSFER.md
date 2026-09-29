# Commands, file transfer, and acknowledgement boundaries

APPv2 uses Wear OS Data Layer between the signed watch and phone applications.
The implementation is in `shared/.../Link.kt`, `CollectorRuntime.kt`, and
`core/.../Integrity.kt`. Local recordings remain available on the originating
device after successful transfer.

## Recording commands

Messages at `/collector/v1/command` carry protocol version, sender role, and
command type. Start contains the immutable session UUID, filename stem, suffix,
creation time, and scheduled start time. Both devices use the same session
identity; a filename timestamp alone is not the identity.

- Start must arrive before its five-second scheduled deadline, while the app is
  visible and ready. The state machine refuses busy, expired, duplicate, or
  cancelled identities. The accepted deadline is mapped to local elapsed time.
- Stop identifies exactly one session. A Stop for an earlier session never stops
  a newer recording. Local Stop and saving do not wait for the phone.
- A received Stop is remembered as an ended identity before `stop_ack` is sent.
  This also rejects a reordered Start arriving after cancellation. The bounded
  ended-identity history is persisted; expired Starts are rejected independently.
- Locally sent Stops are retained in `pending_stops` and resent during the hello
  exchange. A matching Stop acknowledgement clears the pending entry. Matching
  inactive status can also clear it; active matching status triggers another
  scoped Stop.
- `stop_ack` acknowledges acceptance of cancellation/stopping. It does **not**
  mean recording files have finished saving or reached the other device.
- Status has an installation ID, persisted process generation and increasing
  sequence. Older/duplicate status and delayed packets from older process
  generations are rejected; retired installation IDs are tracked within the
  receiver process. Connection and status freshness expire separately.

Messages are not a precise synchronization protocol. A shared countdown is not
evidence of aligned sensor, audio, or camera sample clocks. Metadata and visible
status distinguish confirmed recording from absent or unconfirmed phone video.

## Closed-file delivery

1. Only watch directories marked `.closed-watch` are queued. Hidden lifecycle
   and receipt files are not transferred. Each visible file is described by
   session UUID, filename, byte length, and SHA-256, with a Data Layer asset at
   `/collector/v1/file/<session-id>/<filename>`.
2. A completed `putDataItem` means the item was queued in Data Layer. It does not
   mean the phone has verified a usable local file. Data Layer can synchronize
   queued items after reconnection. [DataClient documentation](https://developers.google.com/android/reference/com/google/android/gms/wearable/DataClient)
3. The phone copies the asset into an app-private temporary file, rejects extra
   or missing bytes, synchronizes file bytes, and checks SHA-256. It publishes the
   file by rename only after validation. An existing identical file is accepted
   idempotently; an existing conflicting file is preserved and reported as an
   error. Temporary files are removed on handled failures.
4. Only after verification does the phone publish
   `/collector/v1/receipt/<session-id>/<filename>` containing the same size/hash,
   verification time, and a fresh nonce. The nonce makes repeated successful
   verification observable even when the recording bytes are unchanged.
5. The watch checks that the local session is closed and the local file still
   matches the receipt's size/hash. It records a hidden receipt marker and may
   remove the **transport DataItem** using the watch creator-node URI. The
   original watch file is retained. Transport deletion failure cannot remove
   that original.

The phone receipt establishes that one file was verified locally. It is not a
session-level receipt for all files, a backup guarantee, or a guarantee that the
phone file cannot later be removed. CSV, WAV, and metadata can arrive separately.
File synchronization and rename protect against ordinary interrupted transfers;
physical storage failure and abrupt device power loss remain hardware checks.

## Retry and interruption

Automatic queueing skips files with local receipt markers. Manual Retry from
either interface requests all finalized watch files, including previously
receipted files. Source files are rehashed before queueing. Identical phone files
remain unchanged, while conflicting phone files produce an error.

One watch executor serializes queueing, file verification, and receipt work.
Receiving callbacks copy required values before their DataEvent buffer is
released. The retrieved asset stream and its response resources are closed after
use. Commands and files have separate manifest-registered listener services:
`LinkListener` receives only command messages; `FileListener` receives file and
receipt DataItems. Each service has its own default background callback looper,
so waiting for file work does not block delivery of Start/Stop messages.
The file callback waits for queued operations for at most 150 seconds per task, retaining its
lifetime during bounded verification/receipt work. This wait never runs on the
UI thread; the file-list scan schedules work asynchronously. An interrupted wait
restores the thread's interruption flag; timeout/failure leaves an explicit
pending/retry status and retains source files. A timeout does not cancel an
in-progress file operation. [WearableListenerService documentation](https://developers.google.com/android/reference/com/google/android/gms/wearable/WearableListenerService)

If disconnection, process termination, or a storage error interrupts delivery,
the original recording remains local. Opening the app or refreshing its file
list scans persistent DataItems; Retry republishes closed source files. Background
callbacks cannot prevent forced process termination, and their bounded wait is
not an unconditional delivery guarantee. Completion and reconnection timing depend on the device and Google Play services
and must be exercised on the target watches and phone. Do not treat a queued
status as a verified receipt.

Software checks cover byte preservation, SHA mismatch, truncation, oversized
input, conflicting destinations, interrupted reads, idempotent receipt, and
temporary-file cleanup. Physical validation must include disconnection during
transfer, process termination during receipt, retry after reopening, and actual
watch-to-phone hash comparison.
