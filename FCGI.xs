#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "fcgiapp.h"

#ifndef FALSE
#define FALSE (0)
#endif

#ifndef TRUE
#define TRUE  (1)
#endif

extern char **environ;
static char **requestEnviron = NULL;

typedef struct
{
    Sfdisc_t	disc;
    FCGX_Stream	*stream;
} FCGI_Disc;

static int
sffcgiread(f, buf, n, disc)
Sfio_t*		f;      /* stream involved */
Void_t*		buf;    /* buffer to read into */
int		n;      /* number of bytes to read */
Sfdisc_t*	disc;   /* discipline */
{
    return FCGX_GetStr(buf, n, ((FCGI_Disc *)disc)->stream);
}

static int
sffcgiwrite(f, buf, n, disc)
Sfio_t*		f;      /* stream involved */
Void_t*		buf;    /* buffer to read into */
int		n;      /* number of bytes to read */
Sfdisc_t*	disc;   /* discipline */
{
    n = FCGX_PutStr(buf, n, ((FCGI_Disc *)disc)->stream);
    if (SvTRUEx(perl_get_sv("|", FALSE))) 
	FCGX_FFlush(((FCGI_Disc *)disc)->stream);
    return n;
}

Sfdisc_t *
sfdcnewfcgi(stream)
	FCGX_Stream *stream;
{
    FCGI_Disc*	disc;

    New(1000,disc,1,FCGI_Disc);
    if (!disc) return (Sfdisc_t *)disc;

    disc->disc.exceptf = (Sfexcept_f)NULL;
    disc->disc.seekf = (Sfseek_f)NULL;
    disc->disc.readf = sffcgiread;
    disc->disc.writef = sffcgiwrite;
    disc->stream = stream;
    return (Sfdisc_t *)disc;
}

Sfdisc_t *
sfdcdelfcgi(disc)
    Sfdisc_t*	disc;
{
    Safefree(disc);
    return 0;
}

static int acceptCalled = FALSE;
static int finishCalled = FALSE;
static int isCGI = FALSE;
static FCGX_Stream *in = NULL;

static int 
FCGI_Accept(void)
{
    if(!acceptCalled) {
        /*
         * First call to FCGI_Accept.  Is application running
         * as FastCGI or as CGI?
         */
        isCGI = FCGX_IsCGI();
        acceptCalled = TRUE;
    } else if(isCGI) {
        /*
         * Not first call to FCGI_Accept and running as CGI means
         * application is done.
         */
        return(EOF);
    } else {
	if(!finishCalled) {
            sfdcdelfcgi(sfdisc(PerlIO_stdin(), SF_POPDISC));
            sfdcdelfcgi(sfdisc(PerlIO_stdout(), SF_POPDISC));
            sfdcdelfcgi(sfdisc(PerlIO_stderr(), SF_POPDISC));
	}
    }
    if(!isCGI) {
        FCGX_Stream *out, *error;
        FCGX_ParamArray envp;
        int acceptResult = FCGX_Accept(&in, &out, &error, &envp);
        if(acceptResult < 0) {
            return acceptResult;
        }
        sfdisc(PerlIO_stdin(), sfdcnewfcgi(in));
        sfdisc(PerlIO_stdout(), sfdcnewfcgi(out));
        sfdisc(PerlIO_stderr(), sfdcnewfcgi(error));
	finishCalled = FALSE;
        environ = envp;
    }
    return 0;
}

static void 
FCGI_Finish(void)
{
    if(!acceptCalled || isCGI) {
	return;
    }
    sfdcdelfcgi(sfdisc(PerlIO_stdin(), SF_POPDISC));
    sfdcdelfcgi(sfdisc(PerlIO_stdout(), SF_POPDISC));
    sfdcdelfcgi(sfdisc(PerlIO_stderr(), SF_POPDISC));
    in = NULL;
    FCGX_Finish();
    environ = NULL;
    finishCalled = TRUE;
}

static int 
FCGI_StartFilterData(void)
{
    return in ? FCGX_StartFilterData(in) : -1;
}

static void
FCGI_SetExitStatus(int status)
{
    if (in) FCGX_SetExitStatus(status, in);
}

/*
 * For each variable in the array envp, either set or unset it
 * in the global hash %ENV.
 */
static void
DoPerlEnv(envp, set)
char **envp;
int set;
{
    int i;
    char *p, *p1;
    HV   *hv;
    SV   *sv;
    hv = perl_get_hv("ENV", TRUE);
    for(i = 0; ; i++) {
        if((p = envp[i]) == NULL) {
            break;
        }
        p1 = strchr(p, '=');
        assert(p1 != NULL);
        *p1 = '\0';
        if(set) {
            sv = newSVpv(p1 + 1, 0);
	    /* add magic for future assignments */
            sv_magic(sv, sv, 'e', p, p1 - p);
	    /* call magic for this value ourselves */
	    SvSETMAGIC(sv);
            hv_store(hv, p, p1 - p, sv, 0);
        } else {
            hv_delete(hv, p, p1 - p, G_DISCARD);
        }
        *p1 = '=';
    }
}


MODULE = FCGI		PACKAGE = FCGI


int
accept()

    CODE:
    {
        char **savedEnviron;
        int acceptStatus;
        /*
         * Unmake Perl variable settings for the request just completed.
         */
        if(requestEnviron != NULL) {
            DoPerlEnv(requestEnviron, FALSE);
            requestEnviron = NULL;
        }
        /*
         * Call FCGI_Accept but preserve environ.
         */
        savedEnviron = environ;
        acceptStatus = FCGI_Accept();
        requestEnviron = environ;
        environ = savedEnviron;
        /*
         * Make Perl variable settings for the new request.
         */
        if(acceptStatus >= 0 && !FCGX_IsCGI()) {
            DoPerlEnv(requestEnviron, TRUE);
        } else {
            requestEnviron = NULL;
        }
        RETVAL = acceptStatus;
    }
    OUTPUT:
    RETVAL


void
finish()

    CODE:
    {
        /*
         * Unmake Perl variable settings for the completed request.
         */
        if(requestEnviron != NULL) {
            DoPerlEnv(requestEnviron, FALSE);
            requestEnviron = NULL;
        }
        /*
         * Finish the request.
         */
        FCGI_Finish();
    }


void
set_exit_status(status)

    int status;

    CODE:
    FCGI_SetExitStatus(status);

int
start_filter_data()

    CODE:
    RETVAL = FCGI_StartFilterData();

    OUTPUT:
    RETVAL
