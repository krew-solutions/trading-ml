import { describe, it, expect } from 'vitest';
import { Decimal } from './decimal';

describe('Decimal', () => {
  describe('fromString / toString round-trip', () => {
    /* Strings the OCaml `Core.Decimal.to_string` would produce —
     * canonical form (no trailing zeros, no point if integral). The
     * round-trip must be exact for our wire format to be a true
     * round-trip across the boundary. */
    const canonical = [
      '0', '1', '-1', '100', '-100',
      '0.1', '0.10000001', '100.10', /* will normalise */
      '100.1', '-100.1',
      '99999999.99999999',
      '-99999999.99999999',
    ];
    for (const s of canonical) {
      it(`${JSON.stringify(s)} parses then re-serialises`, () => {
        const d = Decimal.fromString(s);
        const out = d.toString();
        // 100.10 → 100.1 (canonical trims trailing zeros)
        expect(out).toBe(s.replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, ''));
      });
    }
  });

  describe('canonicalisation', () => {
    it('drops trailing zeros in the fraction', () => {
      expect(Decimal.fromString('100.10000000').toString()).toBe('100.1');
    });
    it('drops the decimal point when value is integral', () => {
      expect(Decimal.fromString('5.00000000').toString()).toBe('5');
    });
    it('truncates fraction past 8 digits (no rounding)', () => {
      expect(Decimal.fromString('0.123456789').toString()).toBe('0.12345678');
    });
    it('pads short fraction to scale', () => {
      expect(Decimal.fromString('0.1').toRaw()).toBe(10_000_000n);
    });
    it('accepts a leading +', () => {
      expect(Decimal.fromString('+1.5').toString()).toBe('1.5');
    });
    it('handles a missing whole part', () => {
      expect(Decimal.fromString('.25').toString()).toBe('0.25');
    });
    it('rejects empty', () => {
      expect(() => Decimal.fromString('')).toThrow();
    });
    it('rejects garbage', () => {
      expect(() => Decimal.fromString('abc')).toThrow();
      expect(() => Decimal.fromString('1.2.3')).toThrow();
    });
  });

  describe('arithmetic', () => {
    const d = (s: string) => Decimal.fromString(s);
    it('add', () => {
      expect(d('0.1').add(d('0.2')).toString()).toBe('0.3');
    });
    it('sub', () => {
      expect(d('1').sub(d('0.7')).toString()).toBe('0.3');
    });
    it('mul', () => {
      expect(d('100').mul(d('0.05')).toString()).toBe('5');
      expect(d('1.5').mul(d('1.5')).toString()).toBe('2.25');
    });
    it('div', () => {
      expect(d('1').div(d('4')).toString()).toBe('0.25');
      expect(d('1').div(d('3')).toString()).toBe('0.33333333');
    });
    it('div by zero throws', () => {
      expect(() => d('1').div(Decimal.ZERO)).toThrow();
    });
    it('neg / abs', () => {
      expect(d('5').neg().toString()).toBe('-5');
      expect(d('-5').abs().toString()).toBe('5');
    });
  });

  describe('predicates', () => {
    it('cmp / eq / min / max', () => {
      const a = Decimal.fromString('1.1');
      const b = Decimal.fromString('1.2');
      expect(a.cmp(b)).toBe(-1);
      expect(b.cmp(a)).toBe(1);
      expect(a.cmp(Decimal.fromString('1.1'))).toBe(0);
      expect(a.eq(Decimal.fromString('1.1'))).toBe(true);
      expect(Decimal.min(a, b).eq(a)).toBe(true);
      expect(Decimal.max(a, b).eq(b)).toBe(true);
    });
    it('sign predicates', () => {
      expect(Decimal.ZERO.isZero()).toBe(true);
      expect(Decimal.fromString('1').isPositive()).toBe(true);
      expect(Decimal.fromString('-1').isNegative()).toBe(true);
    });
  });

  describe('boundary helpers', () => {
    it('fromInt', () => {
      expect(Decimal.fromInt(42).toString()).toBe('42');
      expect(Decimal.fromInt(-7n).toString()).toBe('-7');
    });
    it('fromNumber goes through canonical decimal string', () => {
      expect(Decimal.fromNumber(1.5).toString()).toBe('1.5');
    });
    it('fromNumber rejects NaN/Infinity', () => {
      expect(() => Decimal.fromNumber(NaN)).toThrow();
      expect(() => Decimal.fromNumber(Infinity)).toThrow();
    });
    it('toNumber is the lossy projection', () => {
      expect(Decimal.fromString('1.5').toNumber()).toBe(1.5);
    });
  });
});
