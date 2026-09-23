/* Bob Jenkins, 1996, Public Domain.
 * https://burtleburtle.net/bob/c/isaac64.c
 * Algorithm unchanged; fixed-width typedefs and a small seed/vector driver.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef uint64_t ub8;
typedef uint8_t ub1;
#define RANDSIZL 8
#define RANDSIZ (1<<RANDSIZL)
ub8 randrsl[RANDSIZ], randcnt;
static ub8 mm[RANDSIZ], aa=0, bb=0, cc=0;
#define ind(mm,x) (*(ub8 *)((ub1 *)(mm)+((x)&((RANDSIZ-1)<<3))))
#define rngstep(mix,a,b,mm,m,m2,r,x) \
{x=*m; a=(mix)+*(m2++); *(m++)=y=ind(mm,x)+a+b; *(r++)=b=ind(mm,y>>RANDSIZL)+x;}
void isaac64(void) {
  ub8 a,b,x,y,*m,*m2,*r,*mend;
  m=mm; r=randrsl; a=aa; b=bb+(++cc);
  for(m=mm,mend=m2=m+(RANDSIZ/2);m<mend;) {
    rngstep(~(a^(a<<21)),a,b,mm,m,m2,r,x);
    rngstep(a^(a>>5),a,b,mm,m,m2,r,x);
    rngstep(a^(a<<12),a,b,mm,m,m2,r,x);
    rngstep(a^(a>>33),a,b,mm,m,m2,r,x);
  }
  for(m2=mm;m2<mend;) {
    rngstep(~(a^(a<<21)),a,b,mm,m,m2,r,x);
    rngstep(a^(a>>5),a,b,mm,m,m2,r,x);
    rngstep(a^(a<<12),a,b,mm,m,m2,r,x);
    rngstep(a^(a>>33),a,b,mm,m,m2,r,x);
  }
  bb=b;aa=a;
}
#define mix(a,b,c,d,e,f,g,h) \
{a-=e;f^=h>>9;h+=a;b-=f;g^=a<<9;a+=b;c-=g;h^=b>>23;b+=c;d-=h;a^=c<<15;c+=d;e-=a;b^=d>>14;d+=e;f-=b;c^=e<<20;e+=f;g-=c;d^=f>>17;f+=g;h-=d;e^=g<<14;g+=h;}
void randinit(int flag) {
 int i;ub8 a,b,c,d,e,f,g,h;aa=bb=cc=0;
 a=b=c=d=e=f=g=h=0x9e3779b97f4a7c13LL;
 for(i=0;i<4;++i){mix(a,b,c,d,e,f,g,h);}
 for(i=0;i<RANDSIZ;i+=8){
  if(flag){a+=randrsl[i];b+=randrsl[i+1];c+=randrsl[i+2];d+=randrsl[i+3];e+=randrsl[i+4];f+=randrsl[i+5];g+=randrsl[i+6];h+=randrsl[i+7];}
  mix(a,b,c,d,e,f,g,h);
  mm[i]=a;mm[i+1]=b;mm[i+2]=c;mm[i+3]=d;mm[i+4]=e;mm[i+5]=f;mm[i+6]=g;mm[i+7]=h;
 }
 if(flag){for(i=0;i<RANDSIZ;i+=8){
  a+=mm[i];b+=mm[i+1];c+=mm[i+2];d+=mm[i+3];e+=mm[i+4];f+=mm[i+5];g+=mm[i+6];h+=mm[i+7];
  mix(a,b,c,d,e,f,g,h);
  mm[i]=a;mm[i+1]=b;mm[i+2]=c;mm[i+3]=d;mm[i+4]=e;mm[i+5]=f;mm[i+6]=g;mm[i+7]=h;
 }}
 isaac64();randcnt=RANDSIZ;
}
int main(int argc,char**argv){
 randrsl[0]=argc>1?strtoull(argv[1],0,10):0;randinit(1);
 for(int i=0;i<300;++i){if(!randcnt){isaac64();randcnt=RANDSIZ;}printf("%016llx",(unsigned long long)randrsl[--randcnt]);}
 return 0;
}
