#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "fcgiapp.h"

#ifndef USE_SFIO
#include <fcntl.h>
#endif

#ifndef FALSE
#define FALSE (0)
#endif

#ifndef TRUE
#define TRUE  (1)
#endif

extern char **environ;
static char **requestEnviron = NULL;

#ifdef USE_SFIO
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
#else

static ssize_t
fcgiread(cookie, buf, n)
void *	cookie;
void *	buf;
size_t	n;
{
    return FCGX_GetStr(buf, n, (FCGX_Stream *)cookie);
}

static ssize_t
fcgiwrite(cookie, buf, n)
void *		cookie;
const void *	buf;
size_t		n;
{
    n = FCGX_PutStr(buf, n, (FCGX_Stream *)cookie);
    if (SvTRUEx(perl_get_sv("|", FALSE))) 
	FCGX_FFlush((FCGX_Stream *)cookie);
    return n;
}

cookie_io_functions_t fcgi_functions = {fcgiread, fcgiwrite, 
    (_IO_fpos_t (*) __P((struct _IO_FILE *, _IO_off_t, int))) NULL, 
    (int (*) __P ((struct _IO_FILE *))) NULL};
#endif

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
#ifdef USE_SFIO
            sfdcdelfcgi(sfdisc(PerlIO_stdin(), SF_POPDISC));
            sfdcdelfcgi(sfdisc(PerlIO_stdout(), SF_POPDISC));
            sfdcdelfcgi(sfdisc(PerlIO_stderr(), SF_POPDISC));
#else
	    fflush(stdout);
	    fflush(stderr);
#endif
	}
    }
    if(!isCGI) {
        FCGX_Stream *out, *error;
        FCGX_ParamArray envp;
#ifndef USE_SFIO
	int sin, sout;
	static int protect = TRUE;
#endif
        int acceptResult = FCGX_Accept(&in, &out, &error, &envp);
        if(acceptResult < 0) {
            return acceptResult;
        }
#ifdef USE_SFIO
        sfdisc(PerlIO_stdin(), sfdcnewfcgi(in));
        sfdisc(PerlIO_stdout(), sfdcnewfcgi(out));
        sfdisc(PerlIO_stderr(), sfdcnewfcgi(error));
#else
	/* avoid closing the FCGI_LISTENSOCK_FILENO */
	if (protect) {
	    sin = fcntl(0, F_DUPFD, 3); sout = fcntl(1, F_DUPFD, 3);
	}
	freopencookie((void *)in, "r", fcgi_functions, stdin);
	freopencookie((void *)out, "w", fcgi_functions, stdout);
	freopencookie((void *)error, "w", fcgi_functions, stderr);
	if (protect) {
	    dup2(sin, 0); dup2(sout, 1);
	    close(sin); close(sout);
	    protect = FALSE;
	}
#endif
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
#ifdef USE_SFIO
    sfdcdelfcgi(sfdisc(PerlIO_stdin(), SF_POPDISC));
    sfdcdelfcgi(sfdisc(PerlIO_stdout(), SF_POPDISC));
    sfdcdelfcgi(sfdisc(PerlIO_stderr(), SF_POPDISC));
#else
    fflush(stdout);
    fflush(stderr);
#endif
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
	    /* call magic for this value ourselves */
            hv_store(hv, p, p1 - p, sv, 0);
	    SvSETMAGIC(sv);
        } else {
            hv_delete(hv, p, p1 - p, G_DISCARD);
        }
        *p1 = '=';
    }
}


MODULE = FCGI		PACKAGE = FCGI


int
accept()

    PROTOTYPE:
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

    PROTOTYPE:
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

    PROTOTYPE:
    CODE:
    FCGI_SetExitStatus(status);

int
start_filter_data()

    PROTOTYPE:
    CODE:
    RETVAL = FCGI_StartFilterData();

    OUTPUT:
    RETVAL
