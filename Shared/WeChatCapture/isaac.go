package main

// ISAAC-64, based on Bob Jenkins' public-domain algorithm (1996):
// https://burtleburtle.net/bob/c/isaac64.c
// Channels consumes the results in reverse order, as big-endian words.
import "encoding/binary"

type isaac64 struct {
	memory, results [256]uint64
	a, b, c         uint64
	remaining       int
}

func newISAAC64(seed uint64) *isaac64 {
	r := &isaac64{}
	r.results[0] = seed
	v := [8]uint64{}
	for i := range v {
		v[i] = 0x9e3779b97f4a7c13
	}
	for i := 0; i < 4; i++ {
		mixISAAC(&v)
	}
	for pass := 0; pass < 2; pass++ {
		for i := 0; i < 256; i += 8 {
			for j := range v {
				if pass == 0 {
					v[j] += r.results[i+j]
				} else {
					v[j] += r.memory[i+j]
				}
			}
			mixISAAC(&v)
			copy(r.memory[i:i+8], v[:])
		}
	}
	r.fill()
	return r
}

func mixISAAC(v *[8]uint64) {
	v[0] -= v[4]
	v[5] ^= v[7] >> 9
	v[7] += v[0]
	v[1] -= v[5]
	v[6] ^= v[0] << 9
	v[0] += v[1]
	v[2] -= v[6]
	v[7] ^= v[1] >> 23
	v[1] += v[2]
	v[3] -= v[7]
	v[0] ^= v[2] << 15
	v[2] += v[3]
	v[4] -= v[0]
	v[1] ^= v[3] >> 14
	v[3] += v[4]
	v[5] -= v[1]
	v[2] ^= v[4] << 20
	v[4] += v[5]
	v[6] -= v[2]
	v[3] ^= v[5] >> 17
	v[5] += v[6]
	v[7] -= v[3]
	v[4] ^= v[6] << 14
	v[6] += v[7]
}

func (r *isaac64) fill() {
	r.c++
	r.b += r.c
	for i := range r.memory {
		x := r.memory[i]
		switch i % 4 {
		case 0:
			r.a = ^(r.a ^ (r.a << 21))
		case 1:
			r.a ^= r.a >> 5
		case 2:
			r.a ^= r.a << 12
		case 3:
			r.a ^= r.a >> 33
		}
		r.a += r.memory[(i+128)&255]
		y := r.memory[(x>>3)&255] + r.a + r.b
		r.memory[i] = y
		r.b = r.memory[(y>>11)&255] + x
		r.results[i] = r.b
	}
	r.remaining = 256
}

func (r *isaac64) next() uint64 {
	if r.remaining == 0 {
		r.fill()
	}
	r.remaining--
	return r.results[r.remaining]
}

func keyStream(seed uint64, length int) []byte {
	r := newISAAC64(seed)
	stream := make([]byte, (length+7)/8*8)
	for i := 0; i < len(stream); i += 8 {
		binary.BigEndian.PutUint64(stream[i:i+8], r.next())
	}
	return stream[:length]
}

func xorAt(data, stream []byte, offset int64) {
	if offset < 0 || offset >= int64(len(stream)) {
		return
	}
	for i := 0; i < len(data) && offset+int64(i) < int64(len(stream)); i++ {
		data[i] ^= stream[int(offset)+i]
	}
}
