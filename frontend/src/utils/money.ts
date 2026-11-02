// Every amount in the database is a BIGINT of "minor units" (paise/cents)
// specifically to avoid floating-point rounding bugs. The ONLY place
// that should ever convert back to a decimal display string is the UI
// layer, right before rendering -- never in a calculation.

const SYMBOLS: Record<string, string> = { INR: "₹", USD: "$", EUR: "€" };

export function formatMoney(minor: number, currency: string): string {
  const major = minor / 100;
  const symbol = SYMBOLS[currency] ?? currency + " ";
  return `${symbol}${major.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function toMinorUnits(major: number): number {
  return Math.round(major * 100);
}
