use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'      => 'FCGI',
    'VERSION'	=> '0.25',
    'OBJECT'	=> 'fcgiapp.o FCGI.o',
    'dist'	=> {'COMPRESS'=>'gzip -9f', 'SUFFIX'=>'gz'},
);
