// STM32duino build options for the COMMU relay.
//
// radio.transmit() blocks ~48 ms; during a chunked transfer a beacon (~32 B)
// plus a chunk copy (~44 B) can exceed the 64-byte default core UART buffers
// and drop bytes mid-transmit (D11). Enlarging the core RX/TX buffers fixes it.
//
// This file is consumed by the STM32duino core at compile time (a sketch
// #define does NOT work — the core is a separate translation unit). Verify it
// took effect by printing SERIAL_RX_BUFFER_SIZE once in setup().
-DSERIAL_RX_BUFFER_SIZE=256 -DSERIAL_TX_BUFFER_SIZE=256
