package ws

import "net/http"

// RemoteIPForUnauthSemaphoreExport exposes remoteIPForUnauthSemaphore for
// external _test packages. M1-4 follow-up regression coverage.
func RemoteIPForUnauthSemaphoreExport(remoteAddr string, header http.Header) string {
	return remoteIPForUnauthSemaphore(remoteAddr, header)
}
