use ExtUtils::MakeMaker;
use IO::File;
use Config;

@h = qw(fastcgi.h fcgiapp.h fcgiappmisc.h fcgimisc.h fcgi_config.h);
@o = qw(FCGI.o);
@prefix = qw(/usr /usr/local);
for $dir (@prefix) {
    if (-d "$dir/include" && -d "$dir/lib/" &&
	-f "$dir/lib/libfcgi.a" && !grep {!-f "$dir/include/$_"} (@h)) {
	print "Found fcgi library and include files in $dir\n";
	print "Will be using that instead of included files\n";
	print "Edit Makefile.PL if you don't like it\n";
	$prefix = $dir;
	push @libs, ('-lfcgi', "-L$dir/lib");
    }
}
$sys = $^O eq 'MSWin32' ? 'win32' : 'unix';
push @o, "fcgiapp.o", "os_$sys.o" unless $prefix;
$inc = $prefix ? "-I$prefix/include" : '-I.';


# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'      => 'FCGI',
    'VERSION'	=> '0.37',
    'LIBS'	=> [ @libs ],
    'OBJECT'	=> "@o",
    'INC'	=> $inc,
    'dist'	=> {'COMPRESS'=>'gzip -9f', 'SUFFIX'=>'gz'},
);

exit if -f 'fcgi_config.h' or $prefix;

system("./configure");
