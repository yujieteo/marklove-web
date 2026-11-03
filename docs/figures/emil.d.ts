export type Scale = readonly [string, string, string, string, string, string, string, string, string, string, string, string];

export interface Style {
    fill?: string;
    stroke?: string;
    r?: number;
    width?: number;
}

export interface TextStyle {
    size?: number;
    anchor?: "start" | "middle" | "end";
    valign?: "middle";
    color?: string;
    weight?: number;
}

export interface ArrowStyle {
    stroke: string;
    width: number;
    head: number;
    headWidth: number;
}

export interface Root {
    readonly kind: "root";
}

export interface FigureHandle {
    readonly root: Root;
}

export interface Layout {
    text(root: Root, x: number, y: number, text: string, style: TextStyle): void;
    rect(root: Root, x: number, y: number, w: number, h: number, style: Style): void;
    arrow(root: Root, from: readonly [number, number], to: readonly [number, number], style: ArrowStyle): void;
}

export interface EmilTools {
    s: number;
    r: { chip: number; card: number };
    line: { thin: number; bold: number };
}

export const gray: { 100: string; 400: string; 1100: string; 1200: string };
export const hue: { orange: Scale; blue: Scale; tomato: Scale };
export const weight: { text: number; name: number; title: number };
export function useEmil(figure: FigureHandle, layout: Layout, venue: "web"): EmilTools;
export function card(radius: number): Style;
export function emilTheme(figure: FigureHandle): void;
