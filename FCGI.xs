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

#ifdef USE_SFIO
typedef struct
{
    Sfdisc_t	disc;
    FCGX_Stream	*stream;
} FCGI_Disc;

static ssize_t
sffcgiread(f, buf, n, disc)
Sfio_t*		f;      /* stream involved */
Void_t*		buf;    /* buffer to read into */
size_t		n;      /* number of bytes to read */
Sfdisc_t*	disc;   /* discipline */
{
    return FCGX_GetStr(buf, n, ((FCGI_Disc *)disc)->stream);
}

static ssize_t
sffcgiwrite(f, buf, n, disc)
Sfio_t*		f;      /* stream involved */
const Void_t*	buf;    /* buffer to read into */
size_t		n;      /* number of bytes to read */
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
#endif

static int acceptCalled = FALSE;
static int finishCalled = FALSE;
static int isCGI = FALSE;
static FCGX_Stream *in = NULL;
static SV *svout = NULL, *svin, *sverr;

static int 
FCGI_Flush(void)
{
#ifdef USE_SFIO
    sfsync(PerlIO_stdout());
    sfsync(PerlIO_stderr());
#else
    FCGX_FFlush((FCGX_Stream *) SvIV((SV*) SvRV(svout)));
    FCGX_FFlush((FCGX_Stream *) SvIV((SV*) SvRV(sverr)));
#endif
}

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
	    FCGI_Flush();
#endif
	}
    }
    if(!isCGI) {
        FCGX_ParamArray envp;
	FCGX_Stream *out, *error;
        int acceptResult = FCGX_Accept(&in, &out, &error, &envp);
        if(acceptResult < 0) {
            return acceptResult;
        }
#ifdef USE_SFIO
        sfdisc(PerlIO_stdin(), sfdcnewfcgi(in));
        sfdisc(PerlIO_stdout(), sfdcnewfcgi(out));
        sfdisc(PerlIO_stderr(), sfdcnewfcgi(error));
#else
	if (!svout) {
	    newSVrv(svout = newSV(0), "FCGI");
	    sv_magic((SV *)gv_fetchpv("STDOUT",TRUE, SVt_PVIO), 
			svout, 'q', Nullch, 0);
	    newSVrv(sverr = newSV(0), "FCGI");
	    sv_magic((SV *)gv_fetchpv("STDERR",TRUE, SVt_PVIO), 
			sverr, 'q', Nullch, 0);
	    newSVrv(svin = newSV(0), "FCGI");
	    sv_magic((SV *)gv_fetchpv("STDIN",TRUE, SVt_PVIO), 
			svin, 'q', Nullch, 0);
	}
	sv_setiv(SvRV(svout), (IV) out);
	sv_setiv(SvRV(sverr), (IV) error);
	sv_setiv(SvRV(svin), (IV) in);
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
    FCGI_Flush();
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


typedef FCGX_Stream *	FCGI;

MODULE = FCGI		PACKAGE = FCGI

#ifndef USE_SFIO
void
PRINT(stream, ...)
	FCGI	stream;

	PREINIT:
	int	n;

	CODE:
	for (n = 1; n < items; ++n)
	    FCGX_PutS((char *)SvPV(ST(n),na), stream);
	if (SvTRUEx(perl_get_sv("|", FALSE))) 
	    FCGX_FFlush(stream);

int
WRITE(stream, bufsv, len, ...)
	FCGI	stream;
	SV *	bufsv;
	int	len;

	PREINIT:
	int	offset;
	char *	buf;
	STRLEN	blen;
	int	n;

	CODE:
	offset = (items == 4) ? (int)SvIV(ST(3)) : 0;
	buf = SvPV(bufsv, blen);
	if (offset < 0) offset += blen;
	if (len > blen - offset)
	    len = blen - offset;
	if (offset < 0 || offset >= blen ||
		(n = FCGX_PutStr(buf+offset, len, stream)) < 0) 
	    ST(0) = &sv_undef;
	else {
	    ST(0) = sv_newmortal();
	    sv_setpvn(ST(0), (char *)&n, 1);
	}

int
READ(stream, bufsv, len, offset)
	FCGI	stream;
	SV *	bufsv;
	int	len;
	int	offset;

	PREINIT:
	char *	buf;

	CODE:
	if (! SvOK(bufsv))
	    sv_setpvn(bufsv, "", 0);
	buf = SvGROW(bufsv, len+offset+1);
	len = FCGX_GetStr(buf+offset, len, stream);
	SvCUR_set(bufsv, len+offset);
	*SvEND(bufsv) = '\0';
	(void)SvPOK_only(bufsv);
	SvSETMAGIC(bufsv);
	RETVAL = len;

	OUTPUT:
	RETVAL

SV *
GETC(stream)
	FCGI	stream;

	PREINIT:
	int	retval;

	CODE:
	if ((retval = FCGX_GetChar(stream)) != -1) {
	    ST(0) = sv_newmortal();
	    sv_setpvn(ST(0), (char *)&retval, 1);
	} else ST(0) = &sv_undef;

bool
CLOSE(stream)
	FCGI	stream;

	ALIAS:
	DESTROY = 1

	CODE:
	RETVAL = FCGX_FClose(stream) != -1;

	OUTPUT:
	RETVAL

#endif

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
flush()

    PROTOTYPE:
    CODE:
    FCGI_Flush();

void
set_exit_status(status)

    int status;

    PROTOTYPE: $
    CODE:
    FCGI_SetExitStatus(status);

int
start_filter_data()

    PROTOTYPE:
    CODE:
    RETVAL = FCGI_StartFilterData();

    OUTPUT:
    RETVAL
