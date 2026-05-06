/**
 * Fixed-point decimal mirroring OCaml `Core.Decimal` (`strategy/lib/domain/core/decimal.ml`).
 *
 * Same scale (10^8), same parse rules, same canonical string output —
 * so a string produced by either side round-trips bit-exactly through
 * the other's parser. Backed by `BigInt`; the OCaml side uses `int64`.
 *
 * Use this at the HTTP boundary for monetary fields. Inside the UI
 * the chart libraries take `number`, so most consumers pass through
 * `toNumber()` after parsing.
 */
export class Decimal {
  static readonly SCALE = 8;
  static readonly UNIT = 100_000_000n;

  /** Construct via `Decimal.fromString` / `fromInt` / `fromNumber`. */
  private constructor(private readonly raw: bigint) {}

  static readonly ZERO = new Decimal(0n);
  static readonly ONE = new Decimal(Decimal.UNIT);

  static fromInt(n: number | bigint): Decimal {
    const b = typeof n === 'bigint' ? n : BigInt(n);
    return new Decimal(b * Decimal.UNIT);
  }

  /** Lossy: `n` is IEEE 754. Use only when the source is already a JS
   *  number (e.g. a `<input type="number">`); for anything that came
   *  off the wire use `fromString`. */
  static fromNumber(n: number): Decimal {
    if (!Number.isFinite(n)) {
      throw new Error(`Decimal.fromNumber: non-finite ${n}`);
    }
    return Decimal.fromString(n.toString());
  }

  /**
   * Parses `[-+]?\d+(\.\d+)?`. Truncates fractional part beyond
   * 8 digits (no rounding) and pads shorter ones with trailing zeros —
   * matches the OCaml implementation's behaviour.
   */
  static fromString(s: string): Decimal {
    const trimmed = s.trim();
    if (trimmed === '') {
      throw new Error('Decimal.fromString: empty');
    }
    let rest = trimmed;
    let neg = false;
    if (rest[0] === '-') {
      neg = true;
      rest = rest.slice(1);
    } else if (rest[0] === '+') {
      rest = rest.slice(1);
    }
    const dot = rest.indexOf('.');
    const wholeStr = dot < 0 ? rest : rest.slice(0, dot);
    let fracStr = dot < 0 ? '' : rest.slice(dot + 1);
    if (fracStr.length > Decimal.SCALE) {
      fracStr = fracStr.slice(0, Decimal.SCALE);
    } else {
      fracStr = fracStr + '0'.repeat(Decimal.SCALE - fracStr.length);
    }
    if (wholeStr === '' && fracStr === '0'.repeat(Decimal.SCALE)) {
      return Decimal.ZERO;
    }
    if (!/^\d*$/.test(wholeStr) || !/^\d*$/.test(fracStr)) {
      throw new Error(`Decimal.fromString: invalid ${JSON.stringify(s)}`);
    }
    const w = wholeStr === '' ? 0n : BigInt(wholeStr);
    const f = fracStr === '' ? 0n : BigInt(fracStr);
    const v = w * Decimal.UNIT + f;
    return new Decimal(neg ? -v : v);
  }

  /**
   * Canonical decimal string: no trailing zeros in the fractional
   * part, no decimal point if the value is integral, leading `-`
   * for negatives. Bit-exact with `Core.Decimal.to_string`.
   */
  toString(): string {
    const sign = this.raw < 0n ? '-' : '';
    const abs = this.raw < 0n ? -this.raw : this.raw;
    const whole = abs / Decimal.UNIT;
    const frac = abs % Decimal.UNIT;
    if (frac === 0n) return `${sign}${whole}`;
    const padded = frac.toString().padStart(Decimal.SCALE, '0');
    const trimmed = padded.replace(/0+$/, '');
    return `${sign}${whole}.${trimmed}`;
  }

  /** Lossy projection for chart libraries that take `number`. */
  toNumber(): number {
    return Number(this.toString());
  }

  /** Underlying scaled integer. Exposed for tests / debugging. */
  toRaw(): bigint {
    return this.raw;
  }

  add(b: Decimal): Decimal {
    return new Decimal(this.raw + b.raw);
  }
  sub(b: Decimal): Decimal {
    return new Decimal(this.raw - b.raw);
  }
  /** `(a * b) / unit`. BigInt has unbounded precision, so no need
   *  for the int64 hi/lo split that the OCaml side uses. */
  mul(b: Decimal): Decimal {
    return new Decimal((this.raw * b.raw) / Decimal.UNIT);
  }
  /** `(a * unit) / b`. Throws on division by zero. */
  div(b: Decimal): Decimal {
    if (b.raw === 0n) throw new RangeError('Decimal.div: division by zero');
    return new Decimal((this.raw * Decimal.UNIT) / b.raw);
  }
  neg(): Decimal {
    return new Decimal(-this.raw);
  }
  abs(): Decimal {
    return new Decimal(this.raw < 0n ? -this.raw : this.raw);
  }

  cmp(b: Decimal): -1 | 0 | 1 {
    return this.raw < b.raw ? -1 : this.raw > b.raw ? 1 : 0;
  }
  eq(b: Decimal): boolean {
    return this.raw === b.raw;
  }
  isZero(): boolean {
    return this.raw === 0n;
  }
  isPositive(): boolean {
    return this.raw > 0n;
  }
  isNegative(): boolean {
    return this.raw < 0n;
  }

  static min(a: Decimal, b: Decimal): Decimal {
    return a.cmp(b) <= 0 ? a : b;
  }
  static max(a: Decimal, b: Decimal): Decimal {
    return a.cmp(b) >= 0 ? a : b;
  }
}
