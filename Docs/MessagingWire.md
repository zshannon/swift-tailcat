# Internal typed wire reference

This describes Swift typed request framing, not the [Go mobile bridge protocol](../Bridge/mobile/PROTOCOL.md). Applications use the [typed request API](Messaging.md); stock CLI raw streams do not implement this private protocol. Both application peers must upgrade together when migrating from the old raw EOF/one-byte ACK adapter.

## Frames and limits

Wire version 1 is the framing version, separate from the application event version in `Request.version`. It starts each frame with `TCAT`, a one-byte version, one-byte kind and big-endian UInt32 payload length. Kinds are OPEN=1, INPUT=2, DATA=3, OUTPUT=4, END=5 and ERROR=6.

OPEN contains JSON `{event,version}`, bounded to 512 bytes, and is followed by exactly one INPUT. Payloads are nonempty JSON except zero-byte Void INPUT/OUTPUT. DATA is forbidden on Never lanes. END has zero bytes. Default INPUT/DATA/OUTPUT limit is 8 MiB per encoded frame; ERROR is sanitized JSON bounded to 1024 bytes. Headers are checked before payload allocation, and reads use chunks of at most 65536 bytes.

## Request and response endings

Caller messages are OPEN, INPUT, optional DATA values, then END and EOF. When the inbound lane is absent, canonical END and EOF must be received before invoking the handler. Caller `finishSending` writes END and half-closes the TCP sending direction.

A successful response is optional DATA values followed by **OUTPUT, END, EOF**. A failed response uses **ERROR, END, EOF**: ERROR replaces OUTPUT. Error replies are best effort; a closed transport or failed deadline setup need not deliver ERROR. EOF and the terminal END are validated, rather than treating receipt of OUTPUT or ERROR alone as completion. Handler `finishSending` only revokes further yields; the handler's returned Output still produces the terminal response.

Each flow has one reader and a serialized whole-frame writer. DATA delivery can suspend on the bounded inbox before the reader reaches the terminal value. One lifetime incoming iterator and one result consumer are admitted. Cancellation or an uncertain write closes the affected flow and joins work without automatic replay; the [application error guide](Messaging.md#errors-capacity-and-cancellation) explains side-effect and retry responsibilities.
