//! FFI surface: exactly two symbols. All engine operations go through the
//! JSON dispatcher so the Dart side has a single stable entry point.

use std::ffi::{c_char, CStr, CString};

/// Execute one engine operation. Returns a malloc'd UTF-8 C string:
/// the JSON result, or {"__err": "..."} on failure. Free with gitdeck_free.
#[no_mangle]
pub extern "C" fn gitdeck_call(method: *const c_char, payload: *const c_char) -> *mut c_char {
    let respond = |v: String| -> *mut c_char {
        match CString::new(v) {
            Ok(c) => c.into_raw(),
            Err(_) => CString::into_raw(CString::new("{\"__err\":\"internal: NUL in response\"}").unwrap()),
        }
    };

    let method = match unsafe { CStr::from_ptr(method) }.to_str() {
        Ok(m) => m,
        Err(_) => return respond("{\"__err\":\"method 编码无效\"}".into()),
    };
    let payload_raw = match unsafe { CStr::from_ptr(payload) }.to_str() {
        Ok(p) => p,
        Err(_) => return respond("{\"__err\":\"payload 编码无效\"}".into()),
    };
    let payload: serde_json::Value = match serde_json::from_str(payload_raw) {
        Ok(v) => v,
        Err(e) => return respond(format!("{{\"__err\":\"payload JSON 无效: {e}\"}}")),
    };

    match crate::api::dispatch::call(method, &payload) {
        Ok(v) => respond(v.to_string()),
        Err(e) => respond(serde_json::json!({"__err": e}).to_string()),
    }
}

/// Free a string previously returned by gitdeck_call.
#[no_mangle]
pub extern "C" fn gitdeck_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}
