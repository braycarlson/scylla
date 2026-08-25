fn run() {
    let sum = 1 + 2 * 3 - 4 / 5 % 6;
    let bits = 1 & 2 | 3 ^ 4;
    let shifted = 1 << 2 >> 3;
    let compared = 1 < 2 && 3 > 4 || 5 == 6 && 7 != 8;
    let bounded = 1 <= 2 && 3 >= 4;
    let unary = -1;
    let negated = !true;
    let borrowed = &sum;
    let mutable = &mut sum;
    let dereferenced = *borrowed;
    let cast = 1u32 as u64;
    let call = helper(1, 2);
    let method = value.method(1).chained();
    let turbofish = collect::<Vec<u32>>();
    let field = value.field;
    let index = value.0;
    let indexed = list[0];
    let tuple = (1, 2, 3);
    let single = (1,);
    let empty = ();
    let grouped = (1 + 2) * 3;
    let array = [1, 2, 3];
    let repeated = [0u8; 4];
    let range = 1..2;
    let inclusive = 1..=2;
    let open = 1..;
    let full = ..;
    let closure = |one: u32| one + 1;
    let empty_closure = || 1;
    let typed_closure = |one: u32| -> u32 { one };
    let moved = move |one| one;
    let block = { 1 };
    let unsafe_block = unsafe { 1 };
    let async_block = async { 1 };
    let conditional = if sum > 1 { 1 } else { 2 };
    let matched = match sum {
        0 => 1,
        1 | 2 => 2,
        3..=4 => 3,
        held if held > 5 => 4,
        _ => 5,
    };
    let looped = loop {
        break 1;
    };
    let structured = Held { held: 1 };
    let updated = Held { ..structured };
    let awaited = future.await;
    let question = fallible()?;
    let macro_call = println!("{}", sum);
    let path = std::mem::size_of::<u32>();
    let qualified = <Held as Trait>::CONST;

    sum += 1;
    sum -= 1;
    sum *= 2;
    sum /= 2;
    sum %= 2;
    sum &= 1;
    sum |= 1;
    sum ^= 1;
    sum <<= 1;
    sum >>= 1;
    sum = 1;

    while sum > 0 {
        sum -= 1;

        if sum == 3 {
            continue;
        }

        if sum == 2 {
            break;
        }
    }

    'outer: for item in list {
        for held in item {
            break 'outer;
        }
    }

    while let Some(held) = iterator.next() {
        drop(held);
    }

    if let Some(held) = option {
        drop(held);
    }

    return;
}

// The literal forms and the block expressions no other fixture carries.
const BYTE: u8 = b'h';
const BYTES: &[u8] = b"held";
const CSTRING: &core::ffi::CStr = c"held";
const FLOATING: f64 = 1.0;
const FLAGGED: bool = false;

fn blocks(pair: (u8, u8)) {
    let mut left = 0;
    let counted = const { 1 };
    let attempted = try { 1 };
    let raw = &raw const counted;

    (left, _) = pair;
}

fn generated() {
    yield 1;
}
