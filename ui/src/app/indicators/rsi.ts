/** Relative Strength Index (Wilder smoothing).
 *  RSI = 100 - 100 / (1 + avg_gain/avg_loss).
 *  First [period] diffs seed the averages via their arithmetic mean,
 *  then each subsequent bar uses avg = ((n-1)·avg + x) / n.
 *  If avg_loss is zero, RSI is defined as 100. */

export function rsi(data: number[], period: number): number[] {
  const n = data.length;
  const out = new Array<number>(n).fill(NaN);
  if (n < 2 || period <= 1) return out;

  let sumGain = 0, sumLoss = 0;
  let avgGain = 0, avgLoss = 0;

  for (let i = 1; i < n; i++) {
    const diff = data[i] - data[i - 1];
    const gain = diff > 0 ? diff : 0;
    const loss = diff < 0 ? -diff : 0;

    if (i <= period) {
      sumGain += gain;
      sumLoss += loss;
      if (i === period) {
        avgGain = sumGain / period;
        avgLoss = sumLoss / period;
        out[i] = avgLoss === 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
      }
    } else {
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      out[i] = avgLoss === 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
    }
  }
  return out;
}
