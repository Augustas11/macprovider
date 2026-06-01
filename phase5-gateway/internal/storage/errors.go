package storage

import "errors"

var (
	ErrNotFound            = errors.New("not found")
	ErrBadCursor           = errors.New("bad cursor")
	ErrQuotaExceeded       = errors.New("quota exceeded")
	ErrReservationExists   = errors.New("quota reservation exists")
	ErrReservationNotFound = errors.New("quota reservation not found")
)
