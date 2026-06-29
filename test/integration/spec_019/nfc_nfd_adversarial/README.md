AC-9 NFC/NFD adversarial fixture.

`schema_nfc.json` declares the property name `café` as NFC (`U+0063 U+0061 U+0066 U+00E9`).
`output_nfd.json` emits the visually equivalent NFD key `cafe\u0301`.

The structured-output validator must compare raw decoded key strings without Unicode normalization and reject the output as `json_schema_validation_failed` at `/cafe\u0301`.
