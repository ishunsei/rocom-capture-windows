package livecap

import (
	"fmt"
	"io"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/pcap"
	"github.com/whoisnian/rocom-parse/capture"
)

// Run captures local game traffic through Npcap. Unlike the Linux gateway,
// Windows must retain its own IP addresses (the game may run on this PC).
func Run(e *capture.Engine, iface string) error {
	if err := pcap.LoadWinPCAP(); err != nil {
		return fmt.Errorf("load Npcap: install Npcap from https://npcap.com/: %w", err)
	}
	h, err := pcap.OpenLive(iface, 65535, false, time.Second)
	if err != nil {
		return fmt.Errorf("open Npcap adapter %q (use rocom-interfaces.exe to list adapters; administrator rights may be required): %w", iface, err)
	}
	defer h.Close()
	if e.Port < 1 || e.Port > 65535 {
		return fmt.Errorf("invalid game TCP port: %d", e.Port)
	}
	if err := h.SetBPFFilter(fmt.Sprintf("tcp port %d", e.Port)); err != nil {
		return fmt.Errorf("set Npcap TCP filter: %w", err)
	}
	reader := &packetReader{source: h}
	src := gopacket.NewPacketSource(reader, h.LinkType())
	src.NoCopy = true
	e.Process(src)
	return reader.err
}

// End the packet stream on device errors instead of silently retrying forever.
// gopacket treats EOF as terminal; timeouts are normal for an idle adapter.
type packetReader struct {
	source gopacket.PacketDataSource
	err    error
}

func (r *packetReader) ReadPacketData() ([]byte, gopacket.CaptureInfo, error) {
	for {
		data, ci, err := r.source.ReadPacketData()
		if err == pcap.NextErrorTimeoutExpired {
			continue
		}
		if err != nil {
			if err != io.EOF {
				r.err = fmt.Errorf("Npcap read: %w", err)
			}
			return nil, ci, io.EOF
		}
		return data, ci, nil
	}
}
