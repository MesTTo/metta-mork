use mork::space::{ParDataParser, Space};
use mork_expr::{Expr, ExprZipper};
use mork_frontend::bytestring_parser::{Context, Parser, ParserError};
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

struct MorkState {
    space: Space,
    pending_atoms: Vec<u8>,
}

impl MorkState {
    fn new() -> Self {
        MorkState {
            space: Space::new(),
            pending_atoms: Vec::with_capacity(64 * 1024),
        }
    }
}

//Named spaces: every request may open with a "#mork-space NAME" line
//routing it to that space, created on first use; a request without the
//header works on "default", which keeps the original single-space
//protocol byte-compatible.
struct MorkRegistry {
    spaces: HashMap<String, MorkState>,
}

static GLOBAL_SPACES: OnceLock<Mutex<MorkRegistry>> = OnceLock::new();
fn get_registry() -> &'static Mutex<MorkRegistry> {
    GLOBAL_SPACES.get_or_init(|| {
        Mutex::new(MorkRegistry {
            spaces: HashMap::new(),
        })
    })
}

const SPACE_HEADER: &[u8] = b"#mork-space ";

//Split an optional space header off the payload. Answers the space
//name and the remaining input.
fn split_space_header(inp: &[u8]) -> (String, &[u8]) {
    if let Some(rest) = inp.strip_prefix(SPACE_HEADER) {
        if let Some(nl) = rest.iter().position(|&b| b == b'\n') {
            let name = String::from_utf8_lossy(&rest[..nl]).trim().to_string();
            if !name.is_empty() {
                return (name, &rest[nl + 1..]);
            }
        } else {
            let name = String::from_utf8_lossy(rest).trim().to_string();
            if !name.is_empty() {
                return (name, b"");
            }
        }
    }
    ("default".to_string(), inp)
}

#[repr(C)]
pub struct RustBuffer {
    ptr: *const c_char,
    len: usize,
}

//Reusable output buffer for each thread:
thread_local! {
    static OUTBUF: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(64 * 1024));
}

//S-Expression parsing:
fn parse_sexpr(s: &Space, r: &[u8], buf: &mut [u8]) -> Result<(Expr, usize), ParserError> {
    let mut it = Context::new(r);
    let mut parser = ParDataParser::new(&s.sm);
    let mut ez = ExprZipper::new(Expr {
        ptr: buf.as_mut_ptr(),
    });
    parser.sexpr(&mut it, &mut ez).map(|_| {
        (
            Expr {
                ptr: buf.as_mut_ptr(),
            },
            ez.loc,
        )
    })
}

//Expects `sexpr` to be a tuple `(<pattern> <template>)`.
fn parse_query(
    s: &Space,
    sexpr: &[u8],
    parsebuf: &mut [u8],
) -> Result<Option<(Expr, Expr)>, ParserError> {
    let (qexpr, _used) = parse_sexpr(s, sexpr, parsebuf)?;
    let mut ez = ExprZipper::new(qexpr);
    if !ez.next_child() {
        return Ok(None);
    }
    let pattern = ez.subexpr();
    if !ez.next_child() {
        return Ok(None);
    }
    let template = ez.subexpr();
    if ez.next_child() {
        return Ok(None);
    }
    Ok(Some((pattern, template)))
}

//MORK's own worst-case-optimal conjunctive query, answered read-only.
//
//Space::dump_sexpr already runs this engine. It wraps the caller's single
//pattern into a ONE-factor (, pattern) and hands that to Space::query_multi,
//which is the multi-pattern join. So a conjunction sent to "match" arrived as
//(, (, p1 p2)) -- one factor, and that factor a comma expression no atom
//matches -- and answered nothing. That is why the engine split conjunctions
//itself and a MORK join was unreachable through the seam.
//
//This is dump_sexpr with the wrapping removed, so (, p1 .. pn) reaches
//query_multi as the n-factor query it already is. Nothing new is computed and
//no MORK source changes; the join was always there.
//
//&self.btm is an immutable borrow, so this answers without mutating the space.
//The alternative reachable today, writing an (exec ...) atom and running
//mm2-exec, runs the space's whole calculus and leaves its results behind,
//which is what ~> is for and not what a match may do.
fn query_multi_sexpr<W: std::io::Write>(
    space: &Space,
    pattern: Expr,
    template: Expr,
    w: &mut W,
) -> usize {
    //Sized and cleared exactly as dump_sexpr does: the reservation is virtual
    //and every apply writes from index 0 after a clear.
    let mut buffer = Vec::with_capacity(1 << 32);
    unsafe {
        buffer.set_len(1 << 32);
    }
    let mut stack = Vec::new();
    let mut assignments = Vec::new();
    Space::query_multi(&space.btm, pattern, |refs_bindings, _loc| 'query: {
        match refs_bindings {
            Ok(_refs) => break 'query true,
            Err(ref bindings) => {
                //The PATTERN is applied first for its variable numbering, and
                //the template applied at the offsets that produces. Applying
                //the template alone renumbers its variables independently and
                //the row comes back with the wrong bindings.
                buffer.clear();
                let (oi, ni, true) = mork_expr::apply_e_clears_stacks_and_cycles_check!(
                    0, 0, 0, pattern, bindings, buffer, stack, assignments
                ) else {
                    break 'query true;
                };
                buffer.clear();
                let (_, _, true) = mork_expr::apply_e_clears_stacks_and_cycles_check!(
                    0, oi, ni, template, bindings, buffer, stack, assignments
                ) else {
                    break 'query true;
                };
            }
        }
        Expr {
            ptr: buffer.as_ptr().cast_mut(),
        }
        .serialize2(
            w,
            |s| unsafe { std::mem::transmute(std::str::from_utf8_unchecked(s)) },
            |i, _intro| Expr::VARNAMES[i as usize],
        );
        let _ = w.write(&[b'\n']);
        true
    })
}

fn write_output(outbuf: &mut Vec<u8>, bytes: &[u8]) -> RustBuffer {
    outbuf.clear();
    outbuf.extend_from_slice(bytes);
    output_existing_buffer(outbuf)
}

fn output_existing_buffer(outbuf: &Vec<u8>) -> RustBuffer {
    RustBuffer {
        ptr: outbuf.as_ptr() as *const c_char,
        len: outbuf.len(),
    }
}

fn null_buffer() -> RustBuffer {
    RustBuffer {
        ptr: std::ptr::null(),
        len: 0,
    }
}

fn queue_atom(state: &mut MorkState, atom: &[u8]) {
    state.pending_atoms.extend_from_slice(atom);
    state.pending_atoms.push(b'\n');
}

fn flush_pending_atoms(state: &mut MorkState) -> Result<(), ()> {
    if state.pending_atoms.is_empty() {
        return Ok(());
    }
    let pending = std::mem::take(&mut state.pending_atoms);
    match state.space.add_all_sexpr(&pending) {
        Ok(_) => Ok(()),
        Err(_) => {
            state.pending_atoms = pending;
            Err(())
        }
    }
}

//Foreign Function Interface:
#[no_mangle]
pub extern "C" fn rust_mork(command: *const c_char, input: *const c_char) -> RustBuffer {
    if command.is_null() || input.is_null() {
        return null_buffer();
    }
    let cmd = unsafe { CStr::from_ptr(command) }.to_bytes();
    let raw = unsafe { CStr::from_ptr(input) }.to_bytes();
    let (space_name, inp) = split_space_header(raw);
    let mut result = null_buffer();
    OUTBUF.with(|cell| {
        let mut outbuf = cell.borrow_mut();
        let mut registry = match get_registry().lock() {
            Ok(g) => g,
            Err(_) => {
                result = write_output(&mut outbuf, b"ERR: space poisoned");
                return;
            }
        };
        let s = registry
            .spaces
            .entry(space_name)
            .or_insert_with(MorkState::new);
        if cmd.eq_ignore_ascii_case(b"add-atoms") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            //Add S-exprs into the existing Space
            match s.space.add_all_sexpr(inp) {
                Ok(_) => result = write_output(&mut outbuf, b"OK: loaded"),
                Err(_) => result = write_output(&mut outbuf, b"ERR: load failed"),
            }
        } else if cmd.eq_ignore_ascii_case(b"queue-atom") {
            queue_atom(s, inp);
            result = write_output(&mut outbuf, b"OK: queued");
        } else if cmd.eq_ignore_ascii_case(b"remove-atoms") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            //Remove S-exprs from the existing Space
            match s.space.remove_all_sexpr(inp) {
                Ok(_) => result = write_output(&mut outbuf, b"OK: loaded"),
                Err(_) => result = write_output(&mut outbuf, b"ERR: load failed"),
            }
        } else if cmd.eq_ignore_ascii_case(b"mm2-exec") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            let num = std::str::from_utf8(inp)
                .ok()
                .and_then(|t| t.trim().parse::<usize>().ok())
                .unwrap_or(1);
            //Run the MM2 calculus inside this space
            s.space.metta_calculus(num);
            result = write_output(&mut outbuf, b"OK: executed");
        } else if cmd.eq_ignore_ascii_case(b"query-multi") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            let mut parsebuf = [0u8; 4096];
            let (pattern, template) = match parse_query(&s.space, inp, &mut parsebuf) {
                Ok(Some(parts)) => parts,
                Ok(None) => {
                    result = write_output(&mut outbuf, b"ERR: invalid query tuple");
                    return;
                }
                Err(_) => {
                    result = write_output(&mut outbuf, b"ERR: parse failed");
                    return;
                }
            };
            outbuf.clear();
            query_multi_sexpr(&s.space, pattern, template, &mut *outbuf);
            result = output_existing_buffer(&outbuf);
        } else if cmd.eq_ignore_ascii_case(b"flush") {
            match flush_pending_atoms(s) {
                Ok(_) => result = write_output(&mut outbuf, b"OK: flushed"),
                Err(_) => result = write_output(&mut outbuf, b"ERR: load failed"),
            }
        } else if cmd.eq_ignore_ascii_case(b"get-atoms") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            outbuf.clear();
            if let Err(_) = s.space.dump_all_sexpr(&mut *outbuf) {
                result = write_output(&mut outbuf, b"ERR: dump failed");
                return;
            }
            result = output_existing_buffer(&outbuf);
        } else if cmd.eq_ignore_ascii_case(b"match") {
            if flush_pending_atoms(s).is_err() {
                result = write_output(&mut outbuf, b"ERR: load failed");
                return;
            }
            let mut parsebuf = [0u8; 4096];
            let (pattern, template) = match parse_query(&s.space, inp, &mut parsebuf) {
                Ok(Some(parts)) => parts,
                Ok(None) => {
                    result = write_output(&mut outbuf, b"ERR: invalid query tuple");
                    return;
                }
                Err(_) => {
                    result = write_output(&mut outbuf, b"ERR: parse failed");
                    return;
                }
            };
            outbuf.clear();
            //Now dump the query results into the output buffer:
            s.space.dump_sexpr(pattern, template, &mut *outbuf);
            result = output_existing_buffer(&outbuf);
        } else {
            result = null_buffer();
        }
    });
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queued_atoms_are_loaded_together_on_flush() {
        let mut state = MorkState {
            space: Space::new(),
            pending_atoms: Vec::new(),
        };
        queue_atom(&mut state, b"(friend sam tim)");
        queue_atom(&mut state, b"(friend sam joe)");

        let mut before = Vec::new();
        state.space.dump_all_sexpr(&mut before).unwrap();
        assert!(before.is_empty());

        flush_pending_atoms(&mut state).unwrap();
        let mut after = Vec::new();
        state.space.dump_all_sexpr(&mut after).unwrap();
        let after = String::from_utf8(after).unwrap();
        assert!(after.contains("(friend sam tim)\n"));
        assert!(after.contains("(friend sam joe)\n"));
        assert!(state.pending_atoms.is_empty());
    }

    #[test]
    fn space_headers_route_and_default() {
        assert_eq!(
            split_space_header(b"(f 1)"),
            ("default".to_string(), &b"(f 1)"[..])
        );
        assert_eq!(
            split_space_header(b"#mork-space alpha\n(f 1)"),
            ("alpha".to_string(), &b"(f 1)"[..])
        );
        assert_eq!(
            split_space_header(b"#mork-space beta"),
            ("beta".to_string(), &b""[..])
        );
    }

    #[test]
    fn match_queries_require_exactly_pattern_and_template() {
        let space = Space::new();
        let mut buffer = [0u8; 4096];

        assert!(
            parse_query(&space, b"((friend $x) (friend $x))", &mut buffer)
                .unwrap()
                .is_some()
        );
        assert!(parse_query(&space, b"(friend)", &mut buffer)
            .unwrap()
            .is_none());
        assert!(
            parse_query(&space, b"((friend $x) (friend $x) extra)", &mut buffer)
                .unwrap()
                .is_none()
        );
    }
}
