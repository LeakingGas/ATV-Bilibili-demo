from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, sys

def grad(w,h,c1,c2,angle=35):
    im=Image.new("RGB",(w,h)); px=im.load()
    a=math.radians(angle); dx,dy=math.cos(a),math.sin(a)
    L=abs(w*dx)+abs(h*dy)
    for y in range(h):
        for x in range(w):
            t=((x*dx+y*dy))/L
            t=min(1,max(0,t))
            px[x,y]=tuple(int(c1[i]+(c2[i]-c1[i])*t) for i in range(3))
    return im

def back(w,h):
    S=2; W,H=w*S,h*S
    im=grad(W//4,H//4,(18,22,48),(10,70,92)).resize((W,H),Image.BICUBIC)
    # soft glow
    glow=Image.new("RGBA",(W,H),(0,0,0,0)); d=ImageDraw.Draw(glow)
    d.ellipse((W*0.35,H*0.1,W*1.05,H*1.2),fill=(64,200,220,70))
    d.ellipse((-W*0.2,H*0.4,W*0.45,H*1.3),fill=(150,90,230,60))
    glow=glow.filter(ImageFilter.GaussianBlur(W*0.08))
    im=Image.alpha_composite(im.convert("RGBA"),glow)
    return im.resize((w,h),Image.LANCZOS)

def screen(w,h):
    S=2; W,H=w*S,h*S
    im=Image.new("RGBA",(W,H),(0,0,0,0)); d=ImageDraw.Draw(im)
    sw,sh=W*0.62,H*0.66; x0,y0=(W-sw)/2,(H-sh)/2-H*0.02
    sh_=Image.new("RGBA",(W,H),(0,0,0,0)); ds=ImageDraw.Draw(sh_)
    ds.rounded_rectangle((x0,y0+H*0.03,x0+sw,y0+sh+H*0.03),radius=H*0.09,fill=(0,0,0,110))
    sh_=sh_.filter(ImageFilter.GaussianBlur(H*0.04))
    im=Image.alpha_composite(im,sh_); d=ImageDraw.Draw(im)
    d.rounded_rectangle((x0,y0,x0+sw,y0+sh),radius=H*0.09,fill=(255,255,255,38),outline=(255,255,255,150),width=int(H*0.012))
    # stand
    d.rounded_rectangle((W/2-W*0.09,y0+sh+H*0.04,W/2+W*0.09,y0+sh+H*0.065),radius=H*0.02,fill=(255,255,255,130))
    return im.resize((w,h),Image.LANCZOS)

def bars(w,h):
    # 播放三角形，由几条平行的「线程」横条拼成
    S=2; W,H=w*S,h*S
    th=H*0.42; tw=th*0.9
    cx,cy=W*0.5,H*0.47
    x0=cx-tw/3; x1=x0+tw
    tri=Image.new("L",(W,H),0); dt=ImageDraw.Draw(tri)
    r=H*0.03
    dt.polygon([(x0,cy-th/2),(x1,cy),(x0,cy+th/2)],fill=255)
    tri=tri.filter(ImageFilter.GaussianBlur(r*0.35)).point(lambda v:255 if v>128 else 0)
    n=6; gap=th/n
    mask=Image.new("L",(W,H),0); dm=ImageDraw.Draw(mask)
    for k in range(n):
        y=cy-th/2+gap*k+gap*0.14
        dm.rectangle((0,y,W,y+gap*0.72),fill=255)
    from PIL import ImageChops
    m=ImageChops.multiply(tri,mask)
    colors=Image.new("RGBA",(W,H))
    cols=[(255,140,170),(255,175,150),(255,255,255),(255,255,255),(140,230,240),(150,170,255)]
    dc=ImageDraw.Draw(colors)
    for k in range(n):
        y=cy-th/2+gap*k
        dc.rectangle((0,y,W,y+gap),fill=cols[k]+(255,))
    fg=Image.new("RGBA",(W,H),(0,0,0,0)); fg.paste(colors,(0,0),m)
    sh=Image.new("RGBA",(W,H),(0,0,0,0)); sh.paste((0,0,0,130),(0,int(H*0.015)),m)
    sh=sh.filter(ImageFilter.GaussianBlur(H*0.015))
    out=Image.alpha_composite(sh,fg)
    return out.resize((w,h),Image.LANCZOS)

def flat(w,h):
    return Image.alpha_composite(Image.alpha_composite(back(w,h),screen(w,h)),bars(w,h))

def shelf(w,h):
    im=back(w,h)
    ih=int(h*0.82); iw=int(ih*5/3)
    ic=Image.alpha_composite(screen(iw,ih),bars(iw,ih))
    ix=int(w*0.04); im.alpha_composite(ic,(ix,(h-ih)//2))
    d=ImageDraw.Draw(im)
    x=ix+iw+int(w*0.01); avail=w-x-int(w*0.04)
    title="Bili-ATV-MultiThread"; sub="Multi-CDN streaming for Apple TV"
    size=int(h*0.11)
    while True:
        f1=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",size)
        if d.textlength(title,font=f1)<=avail or size<20: break
        size-=2
    f2=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",int(size*0.45))
    d.text((x,int(h*0.40)),title,font=f1,fill=(255,255,255,240))
    d.text((x,int(h*0.40)+int(size*1.25)),sub,font=f2,fill=(220,235,245,200))
    return im

if __name__=="__main__":
    flat(800,480).save("preview_icon.png")
    shelf(2320,720).convert("RGB").save("preview_shelf.png")
