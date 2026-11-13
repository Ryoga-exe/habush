// SPDX-License-Identifier: Unicode-3.0
// Copyright © 2026 Unicode, Inc. See unicode-LICENSE.txt.
// Derived from https://www.unicode.org/Public/18.0.0/security/confusables.txt
// SHA-256: 6ed3ee967c9dfdf6677d563c9985182fbc50a2efb7d6059cd57b2e2ce18f5b92
// Select single sources named GREEK/CYRILLIC whose targets are ASCII alphanumerics.
// This subset is for advisory heuristics, not the full UTS #39 skeleton algorithm.
pub const ascii_lookalikes = [_]u21{
    'Ꙅ', // 2
    'З',
    'Ӡ',
    '𝈆', // 3
    'б', // 6
    'ᲄ',
    '𝈒', // 7
    'Α',
    'А', // A
    'Ӕ', // AE
    'Β',
    'В', // B
    'Ϲ',
    'С', // C
    'Ε',
    'Е', // E
    'Ϝ',
    '𝈓', // F
    'Ԍ', // G
    'Η',
    'Н', // H
    'Ϳ',
    'Ј', // J
    'Κ',
    'К', // K
    '𝈪', // L
    'Μ',
    'Ϻ',
    'М', // M
    'Ν', // N
    'Ο',
    'О', // O
    'Ꚙ', // OO
    'Ѹ', // Oy
    'Ρ',
    'Р', // P
    'Ԛ', // Q
    '𝈖', // R
    'Ѕ', // S
    'Τ',
    'Т', // T
    'Ѵ',
    '𝈍', // V
    'Ԝ',
    '𝈌', // W
    'Χ',
    'Х', // X
    'Υ',
    'ϒ',
    'У',
    'Ү', // Y
    'Ζ', // Z
    'α',
    'а', // a
    'ӕ', // ae
    'Ь',
    '𝈇', // b
    'Ы', // bl
    'ϲ',
    'с',
    'ᲃ', // c
    'ԁ',
    '𐆋', // d
    'е',
    'ҽ', // e
    '𐅾', // f
    'Һ',
    'һ', // h
    'ι',
    'і',
    'ꙇ', // i
    'ϳ',
    'ј', // j
    'Ι',
    'І',
    'Ӏ',
    'ӏ', // l
    'Ю', // lO
    'ο',
    'σ',
    'о',
    'ᲂ', // o
    'ꚙ', // oo
    'ѹ', // oy
    'ρ',
    'ϱ',
    'ϸ',
    'р', // p
    'ԛ', // q
    'г',
    'ᴦ', // r
    'ѕ', // s
    'υ', // u
    'ν',
    'ѵ', // v
    'ш',
    'ѡ',
    'ԝ', // w
    'х', // x
    'γ',
    'у',
    'ү', // y
};
