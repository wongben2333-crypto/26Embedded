const fs=require('fs');
const k="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
const r={};for(let i=0;i<k.length;i++)r[k[i]]=i;
function d(l,rv,g){let D=[],e=4,s=4,n=3,en="",R=[],w,c;const t={val:g(0),position:rv,index:1};
function rb(x){let b=0,m=1<<x,p=1;while(p!=m){let q=t.val&t.position;t.position>>=1;if(t.position==0){t.position=rv;t.val=g(t.index++);}b|=(q>0?1:0)*p;p<<=1;}return b;}
for(let i=0;i<3;i++)D[i]=i;const nx=rb(2);
if(nx==0)c=String.fromCharCode(rb(8));else if(nx==1)c=String.fromCharCode(rb(16));else return"";
D[3]=c;w=c;R.push(c);
while(true){if(t.index>l)return"";let co=rb(n);
if(co==0){D.push(String.fromCharCode(rb(8)));co=s++;e--;}
else if(co==1){D.push(String.fromCharCode(rb(16)));co=s++;e--;}
else if(co==2)return R.join("");
if(e==0){e=Math.pow(2,n);n++;}
if(D[co])en=D[co];else if(co==s)en=w+w.charAt(0);else return null;
R.push(en);D.push(w+en.charAt(0));s++;e--;w=en;
if(e==0){e=Math.pow(2,n);n++;}}}
const h=fs.readFileSync(process.argv[2],'utf8');
const m=h.match(/decompressFromBase64\("([^"]+)"\)/);
fs.writeFileSync("_ibom.json",d(m[1].length,32,i=>r[m[1][i]]));console.log("ok");
