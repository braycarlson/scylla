use crate::bounded::Span;

pub fn write(source: &[u8], region: Span, holes: &[Span], out: &mut [u8]) -> u32 {
    assert!(u32::try_from(source.len()).is_ok());
    assert!(region.end() as usize <= source.len());
    assert!(out.len() >= region.length as usize);

    let length = region.length as usize;
    let start = region.offset as usize;

    out[..length].copy_from_slice(&source[start..start + length]);

    for hole in holes {
        blank(region, *hole, &mut out[..length]);
    }

    region.length
}

fn blank(region: Span, hole: Span, out: &mut [u8]) {
    let start = hole.offset.max(region.offset);
    let end = hole.end().min(region.end());

    if end <= start {
        return;
    }

    let first = (start - region.offset) as usize;
    let last = (end - region.offset) as usize;

    assert!(last <= out.len());

    for byte in &mut out[first..last] {
        if *byte == b'\n' {
            continue;
        }

        *byte = b' ';
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_region_without_holes_copies_verbatim() {
        let source = b"before<body>after";

        let region = Span {
            length: 6,
            offset: 6,
        };

        let mut out = [0_u8; 32];

        assert_eq!(write(source, region, &[], &mut out), 6);
        assert_eq!(&out[..6], b"<body>");
    }

    #[test]
    fn a_hole_is_blanked_and_the_length_is_preserved() {
        let source = b"a {{ name }} b";

        let region = Span {
            length: 14,
            offset: 0,
        };

        let hole = Span {
            length: 10,
            offset: 2,
        };

        let mut out = [0_u8; 32];
        let written = write(source, region, &[hole], &mut out);

        assert_eq!(written, 14);
        assert_eq!(&out[..14], b"a            b");
    }

    #[test]
    fn a_hole_keeps_its_line_breaks() {
        let source = b"a {% if x %}\n{% endif %} b";

        let region = Span {
            length: 26,
            offset: 0,
        };

        let holes = [
            Span {
                length: 10,
                offset: 2,
            },
            Span {
                length: 11,
                offset: 13,
            },
        ];

        let mut out = [0_u8; 32];
        let written = write(source, region, &holes, &mut out) as usize;

        assert_eq!(written, 26);
        assert!(out[..written].contains(&b'\n'));
        assert!(!out[..12].contains(&b'\n'));
        assert_eq!(&out[..written], b"a           \n            b");
    }

    #[test]
    fn a_hole_outside_the_region_changes_nothing() {
        let source = b"0123456789";

        let region = Span {
            length: 4,
            offset: 3,
        };

        let holes = [
            Span {
                length: 2,
                offset: 0,
            },
            Span {
                length: 2,
                offset: 8,
            },
        ];

        let mut out = [0_u8; 16];

        assert_eq!(write(source, region, &holes, &mut out), 4);
        assert_eq!(&out[..4], b"3456");
    }

    #[test]
    fn a_hole_that_straddles_the_region_edge_is_clipped() {
        let source = b"0123456789";

        let region = Span {
            length: 4,
            offset: 3,
        };

        let hole = Span {
            length: 4,
            offset: 1,
        };

        let mut out = [0_u8; 16];

        assert_eq!(write(source, region, &[hole], &mut out), 4);
        assert_eq!(&out[..4], b"  56");
    }

    #[test]
    fn byte_soup_masks_without_running_off_the_region() {
        let mut random = crate::bounded::Random::new(0x51ED_270B_6996_1E71);
        let mut out = [0_u8; 256];

        for _ in 0..256 {
            let length = random.below(200) as usize + 1;
            let mut source = Vec::with_capacity(length);

            for _ in 0..length {
                source.push(b" \nabc{}"[random.below(7) as usize]);
            }

            let offset = random.below(crate::bounded::count_of(length));

            let region = Span {
                length: random.below(crate::bounded::count_of(length) - offset + 1),
                offset,
            };

            let holes = [Span {
                length: random.below(32),
                offset: random.below(crate::bounded::count_of(length)),
            }];

            let written = write(&source, region, &holes, &mut out) as usize;

            assert_eq!(written, region.length as usize);

            for (index, byte) in out[..written].iter().enumerate() {
                let held = source[region.offset as usize + index];

                assert!(*byte == held || *byte == b' ');
            }
        }
    }

    #[test]
    fn a_prepared_offset_maps_back_by_adding_the_region_start() {
        let source = b"xxx<div>{{ a }}</div>";

        let region = Span {
            length: 18,
            offset: 3,
        };

        let hole = Span {
            length: 7,
            offset: 8,
        };

        let mut out = [0_u8; 32];
        let written = write(source, region, &[hole], &mut out) as usize;

        let found = out[..written]
            .windows(6)
            .position(|window| window == b"</div>")
            .expect("the close tag survives the blanking");

        assert_eq!(crate::bounded::count_of(found) + region.offset, 15);
    }
}
