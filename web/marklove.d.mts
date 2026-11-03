export interface MarkloveModule {
    HEAPU8: Uint8Array;
    _malloc(size: number): number;
    _free(ptr: number): void;
    _goose_init(a: number, b: number): void;
    _ml_in_alloc(slot: number, size: number): number;
    _ml_pack_import_arg(lenPtr: number): number;
    [name: `_ml_${string}`]: (...args: number[]) => number;
}

export interface MarkloveHooks {
    mlMeasure?: (text: string, font: string) => number;
    mlMath?: (latex: string, display: number, which: number) => number;
}

export default function createModule(hooks?: MarkloveHooks): Promise<MarkloveModule>;
