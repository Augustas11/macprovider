//go:build testfaults

package testfaults

import "net/http"

func PanicHandler(w http.ResponseWriter, r *http.Request) {
	panic("testfaults: controlled coordinator panic")
}
