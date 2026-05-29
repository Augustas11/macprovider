//go:build testfaults

package testfaults

import (
	"context"
	"io"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func DeadMidInferenceRelay(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	chunks <- providerws.InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       0,
		Data:      `{"partial":true}`,
	}
	errs <- providerws.ErrRelayClosed
	return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
}

type SlowReader struct {
	R     io.Reader
	Delay time.Duration
}

func (r SlowReader) Read(p []byte) (int, error) {
	if r.Delay > 0 {
		time.Sleep(r.Delay)
	}
	return r.R.Read(p)
}
