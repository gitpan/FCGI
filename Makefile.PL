use ExtUtils::MakeMaker;
use Config;

if ($Config{'usesfio'} ne 'true' or $Config{'useperlio'} ne 'define') {
    print "Your perl isn't compiled with perlio/sfio support.\n";
    exit 1;
}
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'      => 'FCGI',
    'VERSION'	=> '0.28',
    'OBJECT'	=> 'fcgiapp.o FCGI.o',
    'dist'	=> {'COMPRESS'=>'gzip -9f', 'SUFFIX'=>'gz'},
);
