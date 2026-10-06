using Singularity.Apps.Connections;

void check (string input, string proto, string host, int port) {
    var a = Address.parse (input);
    assert (a != null);
    if (a.protocol != proto || a.host != host || a.port != port) {
        error ("%s: got %s %s %d", input, a.protocol, a.host, a.port);
    }
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/address/forms", () => {
        check ("server", "vnc", "server", 5900);
        check ("server:1", "vnc", "server", 5901);
        check ("server::5999", "vnc", "server", 5999);
        check ("server:5905", "vnc", "server", 5905);
        check ("vnc://10.0.0.2:5901", "vnc", "10.0.0.2", 5901);
        check ("rdp://win.example.com", "rdp", "win.example.com", 3389);
        check ("rdp://win:3390/", "rdp", "win", 3390);
        check ("[fe80::1]:5902", "vnc", "fe80::1", 5902);
        check ("rdp://[2001:db8::7]", "rdp", "2001:db8::7", 3389);
    });
    Test.add_func ("/address/invalid", () => {
        assert (Address.parse ("") == null);
        assert (Address.parse ("ssh://host") == null);
        assert (Address.parse ("host:abc") == null);
        assert (Address.parse ("host:70000") == null);
        assert (Address.parse ("my host") == null);
    });
    Test.add_func ("/address/display", () => {
        var a = Address.parse ("rdp://win:3390");
        assert (a.to_display () == "win:3390");
        var b = Address.parse ("[fe80::1]");
        assert (b.to_display () == "[fe80::1]");
    });
    Test.add_func ("/store/roundtrip", () => {
        string dir = DirUtils.make_tmp ("conn-XXXXXX");
        string file = Path.build_filename (dir, "c.json");
        var s = new Store (file);
        var c = new Connection ();
        c.name = "Office";
        c.protocol = "rdp";
        c.host = "win";
        c.port = 3389;
        c.username = "ada";
        c.view_only = true;
        s.put (c);
        var s2 = new Store (file);
        assert (s2.items.size == 1);
        var d = s2.items[0];
        assert (d.name == "Office" && d.protocol == "rdp" && d.username == "ada" && d.view_only && d.id == c.id);
        FileUtils.remove (file);
        DirUtils.remove (dir);
    });
    Test.run ();
}
