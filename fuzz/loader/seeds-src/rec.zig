return f(a);
}
fn f(n: i32) i32 {
    if (n <= 0) return 0;
    return f(n - 1) +% 1;
