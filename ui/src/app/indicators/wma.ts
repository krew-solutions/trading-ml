/** Weighted Moving Average: linear weights 1..period, weight sum = n(n+1)/2.
 *  Used standalone and as the smoothing kernel for MACD-Weighted. */

export function wma(data: number[], period: number): number[] {
  const out = new Array<number>(data.length).fill(NaN);
  if (!data.length || period <= 0) return out;
  const denom = (period * (period + 1)) / 2;
  for (let i = period - 1; i < data.length; i++) {
    let s = 0;
    for (let j = 0; j < period; j++) s += data[i - j] * (period - j);
    out[i] = s / denom;
  }
  return out;
}
