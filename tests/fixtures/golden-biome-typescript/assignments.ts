let held = 1;

held += 1;
held -= 1;
held *= 2;
held /= 2;
held %= 2;
held **= 2;
held <<= 1;
held >>= 1;
held >>>= 1;
held &= 1;
held |= 1;
held ^= 1;
held &&= 1;
held ||= 1;
held ??= 1;

const shifted = held >> 1;
const unsigned = held >>> 1;
const decremented = held-- - --held;
const loose = held == 1;
const unequal = held != 1;
const atMost = held <= 1;
