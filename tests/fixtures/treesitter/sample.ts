export interface Shape {
  area(): number;
}

export class Circle implements Shape {
  radius: number;
  constructor(r: number) {
    this.radius = r;
  }
  area(): number {
    return Math.PI * this.radius * this.radius;
  }
}

export type Pair = [number, number];

export function midpoint(a: Pair, b: Pair): Pair {
  return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
}

export const ORIGIN: Pair = [0, 0];
