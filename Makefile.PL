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
    'VERSION_FROM'	=> 'FCGI.pm',
    'LIBS'	=> [ @libs ],
    'OBJECT'	=> "@o",
    'INC'	=> $inc,
    'dist'	=> {'COMPRESS'=>'gzip -9f', 'SUFFIX'=>'gz'},
    'clean'	=> { FILES =>'config.cache fcgi_config.h' },
    'PL_FILES'	=> { 'echo.PL'	=>	'echo.fpl',
		     'FCGI.PL'	=>	'FCGI.xs',
		   },
);

if($sys eq "win32") {
  # configure will almost certainly not run on a normal NT install,
  # use the pregenerated configuration file

  print "Using prebuilt fcgi_config.h file for Windows\n";
  unlink("fcgi_config.h");
  die $! unless rename("fcgi_config.w32","fcgi_config.h");

  # Win build system also can't deal with existence of FCGI.xs or absence of
  # FCGI.c
  unlink("FCGI.xs");
  open(F, ">FCGI.c"); close(F);
  $now = time; $before = $now - 600;
  utime $before, $before, "FCGI.c";
  utime $now, $now, "FCGI.PL";

} else {
    exit if -f 'fcgi_config.h' or $prefix;

    print "Running ./configure for you\n";
    print "Please read INSTALL for information on how to run it yourself\n";

    $ENV{'CC'} = $Config{'cc'};
    system("./configure");
}
