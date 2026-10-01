import io, cairosvg
from PIL import Image
from lottie.parsers.tgs import parse_tgs
from lottie.exporters.svg import export_svg
BG=(245,243,252)
for n in ["idle","hello","whoa","tidy","wink"]:
    for suf in ["","-badge"]:
        an = parse_tgs(f"lottie/shotsy-{n}{suf}.json")
        frames=[]
        for f in range(0, int(an.out_point), 2):
            buf=io.StringIO(); export_svg(an, buf, f)
            im=Image.open(io.BytesIO(cairosvg.svg2png(bytestring=buf.getvalue().encode(), output_width=240, output_height=240))).convert("RGBA")
            b=Image.new("RGBA",im.size,BG+(255,)); b.alpha_composite(im); frames.append(b.convert("P", palette=Image.ADAPTIVE))
        hold = [1000 if n!="idle" else 33]
        dur=[33]*(len(frames)-1)+[900 if n!="idle" else 33]
        frames[0].save(f"preview/shotsy-{n}{suf}.gif", save_all=True, append_images=frames[1:], duration=dur, loop=0, disposal=2)
print("gifs ok")
