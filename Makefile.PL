use ExtUtils::MakeMaker;
use Config;

if ($Config{'usesfio'} ne 'true') {
    print "Your perl isn't compiled with sfio support.\n";
    exit 1;
}
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'      => 'FCGI',
    'VERSION'	=> '0.26',
    'OBJECT'	=> 'fcgiapp.o FCGI.o',
    'dist'	=> {'COMPRESS'=>'gzip -9f', 'SUFFIX'=>'gz'},
);
