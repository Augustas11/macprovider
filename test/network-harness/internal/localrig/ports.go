package localrig

import "net"

// allocatePort returns an OS-allocated free TCP port on 127.0.0.1. Racy
// between Close and the child re-listening — in practice the window is
// microseconds and coordinator/gateway listen() retries paper it over.
// If flakes appear, switch to fd-handoff via net.FileListener.
func allocatePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}
