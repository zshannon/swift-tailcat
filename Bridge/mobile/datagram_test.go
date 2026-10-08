package mobile

import (
	"encoding/base64"
	"testing"
	"time"
)

func TestEncryptedUDPEmptyDatagrams(t *testing.T) {
	r, sid, cid := fixture(t)
	_, local, remote := makePair(t, r, sid, cid, "udp")
	successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100}) // flow opener
	for _, id := range []int64{local, remote} {
		successful(t, r, "connection.deadline", map[string]any{"handle": id, "readDeadline": time.Now().Add(2 * time.Second).UnixNano()})
	}
	for _, method := range []string{"connection.read", "connection.readPacket"} {
		t.Run(method, func(t *testing.T) {
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte{}})
			got := successful(t, r, method, map[string]any{"handle": local, "count": 100})
			if got["data"] != "" || got["eof"] != false {
				t.Fatalf("empty datagram must carry data and eof=false: %v", got)
			}
			if method == "connection.readPacket" {
				if _, ok := got["address"].(string); !ok {
					t.Fatalf("empty packet lost its source: %v", got)
				}
				successful(t, r, "connection.writePacket", map[string]any{"handle": local, "data": []byte{}, "address": got["address"]})
			} else {
				successful(t, r, "connection.write", map[string]any{"handle": local, "data": []byte{}})
			}
			got = successful(t, r, method, map[string]any{"handle": remote, "count": 100})
			if got["data"] != "" || got["eof"] != false {
				t.Fatalf("empty reply must remain a datagram: %v", got)
			}
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte("after-empty")})
			got = successful(t, r, method, map[string]any{"handle": local, "count": 100})
			if got["data"] != base64.StdEncoding.EncodeToString([]byte("after-empty")) || got["eof"] != false {
				t.Fatalf("empty datagram ended subsequent traffic: %v", got)
			}
		})
	}
}

func TestRevokedUDPEmptyDatagramsRespectDeadlineAndCancellation(t *testing.T) {
	for _, method := range []string{"connection.read", "connection.readPacket"} {
		t.Run(method, func(t *testing.T) {
			r, sid, cid := fixture(t)
			_, local, remote := makePair(t, r, sid, cid, "udp")
			successful(t, r, "connection.read", map[string]any{"handle": local, "count": 100})
			key := successful(t, r, "client.key", map[string]any{"handle": cid})["key"]
			successful(t, r, "server.revoke", map[string]any{"handle": sid, "key": key})
			successful(t, r, "connection.deadline", map[string]any{"handle": local, "readDeadline": time.Now().Add(100 * time.Millisecond).UnixNano()})
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte{}})
			if a := invoke(t, r, method, map[string]any{"handle": local, "count": 100}); a.code != 5 {
				t.Fatalf("revoked empty datagram should time out, got %d %s %s", a.code, a.result, a.message)
			}
			// Cancellation must interrupt a guarded read and restore the caller's
			// persistent deadline for the next read, rather than leave it expired.
			deadline := time.Now().Add(300 * time.Millisecond)
			successful(t, r, "connection.deadline", map[string]any{"handle": local, "readDeadline": deadline.UnixNano()})
			op, cb := begin(r, method, map[string]any{"handle": local, "count": 100})
			successful(t, r, "connection.write", map[string]any{"handle": remote, "data": []byte{}})
			time.AfterFunc(20*time.Millisecond, op.Cancel)
			if a := await(t, cb); a.code != 2 {
				t.Fatalf("guarded read cancellation: %d %s %s", a.code, a.result, a.message)
			}
			started := time.Now()
			if a := invoke(t, r, method, map[string]any{"handle": local, "count": 100}); a.code != 5 {
				t.Fatalf("restored guarded read deadline: %d %s", a.code, a.message)
			}
			if time.Since(started) < 100*time.Millisecond {
				t.Fatal("cancellation left the read deadline expired")
			}
		})
	}
}
