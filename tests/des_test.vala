using Singularity.Remote;

static string hex (uint8[] data) {
    var sb = new StringBuilder ();
    foreach (uint8 b in data) sb.append_printf ("%02x", b);
    return sb.str;
}

static uint8[] unhex (string s) {
    var res = new uint8[s.length / 2];
    for (int i = 0; i < res.length; i++) res[i] = (uint8) uint64.parse ("0x" + s.substring (i * 2, 2), 16);
    return res;
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/des/known-vector", () => {
        var des = new Des (unhex ("133457799bbcdff1"));
        assert (hex (des.encrypt_block (unhex ("0123456789abcdef"))) == "85e813540f0ab405");
    });
    Test.add_func ("/des/zero-key", () => {
        var des = new Des (unhex ("0000000000000000"));
        assert (hex (des.encrypt_block (unhex ("0000000000000000"))) == "8ca64de9c1b123a7");
    });
    Test.run ();
}
