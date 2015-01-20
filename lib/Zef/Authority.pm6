class Zef::Authority {

    has $.session-key is rw;

    method login(:$username, :$password) {
        use IO::Socket::SSL;
        my $data = to-json({ username => $username, password => $password });
        my $sock = IO::Socket::SSL.new(:host<zef.pm>, :port(443));
        $sock.send("POST /api/login HTTP/1.0\r\nHost: zef.pm\r\nContent-Length: {$data.chars}\r\n\r\n{$data}");
        my $recv = $sock.recv.decode('UTF-8');
        my %result = try {
            CATCH { default { %(); } }
            %(from-json($recv.split("\r\n\r\n")[1]));
        }
        
        if %result<success> {
            say 'Login successful.';
            $.session-key = %result<newkey>;
        } 
        elsif %result<failure> {
            say "Login failed with error: {%result<reason>}";
            return False;
        } 
        else {
            say 'Unknown problem -';
            say %result.perl;
            say $recv;
            return False;
        }

        return True;
    }

    method register(:$username, :$password) {
        use IO::Socket::SSL;
        my $data = to-json({ username => $username, password => $password });
        my $sock = IO::Socket::SSL.new(:host<zef.pm>, :port(443));
        $sock.send("POST /api/register HTTP/1.0\r\nHost: zef.pm\r\nContent-Length: {$data.chars}\r\n\r\n{$data}");
        my %result = try {
            CATCH { default { %(); } }
            %(from-json($sock.recv.decode('UTF-8').split("\r\n\r\n")[1]));
        }
        
        if %result<success> {
            say 'Welcome to Zef.';
            $.session-key = %result<newkey>;
        } 
        elsif %result<failure> {
            say "Registration failed with error: {%result<reason>}";
            return False;
        } 
        else {
            say 'Unknown problem -';
            say %result.perl;
            return False;
        }

        return True;
    }

    method search(*@terms) {
        use IO::Socket::SSL;
        for @terms -> $term {
            CATCH { default { fail "Search error: $_" } }

            my $data = to-json({ query => $term });
            my $sock = IO::Socket::SSL.new(:host<zef.pm>, :port(443));
            $sock.send("POST /api/search HTTP/1.0\r\nHost: zef.pm\r\nContent-Length: {$data.chars}\r\n\r\n{$data}");
            my $recv = $sock.recv.decode('UTF-8');
            
            my @results = @(from-json($recv.split("\r\n\r\n")[1])) // fail "Bad JSON";
            say "No results for $term" && return False unless @results;

            say "Results for $term";
            say "Package\tAuthor\tVersion";
            for @results -> %result {
                say "{%result<name>}\t{%result<owner>}\t{%result<version>}";
            }

            return True;
        }
    }

    method push(*@targets, :$session-key, :@exclude?, :$force?) {
        use MIME::Base64;
        for @targets -> $target {
            my $data = '';
            my @paths = $target.IO.dir;
            my @files;
            my @failures;

            while @paths.shift -> $path {
                next if $path ~~ any @exclude;
                given $path.IO {
                    when :d { for .dir -> $io { @paths.push: $io } }
                    when :f { @files.push($_) }
                }            
            }

            for @files -> $path {
                my $buff = try { 
                        CATCH { default { } }
                        MIME::Base64.encode-str($path.IO.slurp);
                    } // try {
                        my $b = Buf.new;
                        my $f = open $path, :r;
                        while !$f.eof { 
                            $b ~= $f.read(1024); 
                        }
                        $f.close;
                        CATCH { default { } }
                        MIME::Base64.encode($b, one-line => True);
                    } // fail "Failed to encode data";

                if $buff !~~ Str {
                    @failures.push($path);
                    last unless $force;
                } 

                $data ~= "{$path.Str.subst(/ ^ $target /, '')}\r\n{$buff}\r\n";
            }

            if !$force && @failures {
                print "Failed to package the following files:\n\t";
                say @failures.join("\n\t");
            } 

            my $metf = try {'META.info'.IO.slurp} \ 
                or try {'META6.json'.IO.slurp}    \ 
                or die "Couldn't find META6.json or META.info";

            my $json = to-json({ key => $session-key, data => $data, meta => %(from-json($metf)) });
            my $sock = IO::Socket::SSL.new(:host<zef.pm>, :port(443));
            $sock.send("POST /api/push HTTP/1.0\r\nHost: zef.pm\r\nContent-Length: {$json.chars}\r\n\r\n{$json}");
            my $recv   = $sock.recv.decode('UTF-8');
            my %result = try {
                CATCH { default { %() } }
                %(from-json($recv.split("\r\n\r\n")[1]));
            };
            
            if %result<version> {
                say "Successfully pushed version '{%result<version>}' to server";
            } 
            elsif %result<error> {
                say "Error pushing module to server: {%result<error>}";
                return False;
            } 
            else {
                say "Unknown error - Reply from server:\n{%result.perl}";
                return False;
            }

            return True;
        }        
    }
}
