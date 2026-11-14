# /// script
# dependencies = ["numpy", "pillow"]
# ///
"""将 AVG_079_daoguang01 的真实网格与 shader 参数烘焙为 60fps 图集。"""

import json,math,sys
from pathlib import Path
from importlib import import_module

np = import_module('numpy')
Image = import_module('PIL.Image')
sys.path.insert(0,'tool')
from avg_fx_mesh import mesh_geometry,ref
from avg_fx_extract import curve
from avg_fx_json import dumps

if len(sys.argv) != 3:
 raise SystemExit('用法: uv run tool/avg_fx_snake_bake.py <已归一化源目录> <已转换目标目录>')
source=Path(sys.argv[1])
target=Path(sys.argv[2])
try:
 tree=next(iter(json.loads((source/'TT_avg_079_daoguang01.ab.json').read_text(encoding='utf8')).values()))
 data=json.loads((target/'fx.json').read_text(encoding='utf8'))
except (OSError,UnicodeError,ValueError,StopIteration) as error:
 raise ValueError(f'无法读取刀光源文件或目标文件：{error}') from error
transforms={ref(o.get('m_GameObject')):o for o in tree.values() if 'm_LocalPosition' in o}
systems={ref(o.get('m_GameObject')):o for o in tree.values() if 'InitialModule' in o}
renderers={tree[ref(o.get('m_GameObject'))].get('m_Name'):o for o in tree.values() if 'm_Materials' in o and ref(o.get('m_GameObject')) in tree}

def evaluate(c,t):
 c=curve(c); v=c['scalar']; points=c['curve']
 if c['state']==0:return v
 if c['state']!=1:raise ValueError('随机曲线不能烘焙为统一图集')
 if not points:return v
 if t<=points[0][0]:return points[0][1]*v
 for a,b in zip(points,points[1:]):
  if t<=b[0]:
   span=b[0]-a[0];k=(t-a[0])/span;k2=k*k;k3=k2*k
   return v*((2*k3-3*k2+1)*a[1]+(k3-2*k2+k)*span*a[3]+(-2*k3+3*k2)*b[1]+(k3-k2)*span*b[2])
 return points[-1][1]*v

def grad(stops,t):
 if not stops:return np.ones(4)
 return np.array([np.interp(t,[p[0] for p in stops],[p[c] for p in stops]) for c in range(1,5)])

def sample(img,u,v,wrap):
 h,w=img.shape[:2]
 def coord(a,n,mode):
  if mode==1:a=np.clip(a,0,1)
  else:a=np.mod(a,1)
  return np.clip((a*n).astype(int),0,n-1)
 return img[coord(1-v,h,wrap[1]),coord(u,w,wrap[0])]

w,h,fps,columns=256,128,60,8
u,v=np.meshgrid((np.arange(w)+.5)/w,1-(np.arange(h)+.5)/h)
for entry in data['emitters']:
 if not entry['name'].startswith(('slash_bg_01_an','slash_bg_01_line')):continue
 renderer=renderers[entry['name']];go=ref(renderer['m_GameObject']);ps=systems[go]
 material=tree[ref(renderer['m_Materials'][0])]
 props=material['m_SavedProperties'];floats=dict(props['m_Floats']);colors=dict(props['m_Colors']);texenv=dict(props['m_TexEnvs'])
 textures={}
 for key in ('_MainTex','_DissolveTex','_DisturbTex','_RamTex'):
  env=texenv[key];texture=tree.get(ref(env['m_Texture']))
  if texture:
   img=np.asarray(Image.open(source/(texture['m_Name']+'.png')).convert('RGBA'),dtype=np.float32)/255
   sett=texture.get('m_TextureSettings',{});wrap=(sett.get('m_WrapU',0),sett.get('m_WrapV',0))
  elif env['m_Texture']['m_PathID']==0:img=np.ones((1,1,4),dtype=np.float32);wrap=(0,0)
  else:raise ValueError(f"missing {key} {env['m_Texture']}")
  textures[key]=(img,env,wrap)
 def tex(key,du=0,dv=0,t=0.0,speed=''):
  img,env,wrap=textures[key];st=env['m_Scale'];offset=env['m_Offset']
  return sample(img,u*st['x']+offset['x']+du+floats.get('_'+speed+'USpeed',0)*t,v*st['y']+offset['y']+dv+floats.get('_'+speed+'VSpeed',0)*t,wrap)
 def channel(c,which):
  n=round(floats.get(which,0))
  return c if n==0 else np.repeat(c[:,:,n-1:n],4,axis=2)
 size=ps['InitialModule'];life=size['startLifetime']['scalar'];count=math.ceil(life*fps)+1
 atlas=Image.new('RGBA',(w*columns,h*math.ceil(count/columns)))
 custom=ps['CustomDataModule'];color0=grad(entry['startColor'],.5)
 maincolor=np.array([colors.get('_MainColor',dict(r=1,g=1,b=1,a=1))[k] for k in 'rgba'])
 for frame in range(count):
  t=frame/fps;p=min(t/life,1)
  custom0=[evaluate(custom[f'vector0_{i}'],p) for i in range(4)]
  custom1=[evaluate(custom[f'vector1_{i}'],p) for i in range(4)]
  a=tex('_RamTex');a=channel(a,'_RamTexChannel')
  dist=tex('_DisturbTex',custom1[2],custom1[3],t,'Disturb');di=round(floats.get('_DisturbTexChannel',0));dist=dist[:,:,0 if di==0 else di-1]
  du=(floats.get('_IntensityU',0)+custom1[1])*dist;dv=(floats.get('_IntensityV',0)+custom1[1])*dist
  main=tex('_MainTex',custom0[0]+du*floats.get('_DisturbInfluenceMainUV',1),custom0[1]+dv*floats.get('_DisturbInfluenceMainUV',1),t,'Main');main=channel(main,'_MainTexChannel')
  dissolve=tex('_DissolveTex',custom0[2]+du*floats.get('_DisturbInfluenceDissolveUV',1),custom0[3]+dv*floats.get('_DisturbInfluenceDissolveUV',1),t,'Dissolve');di=round(floats.get('_DissolvTexChannel',0));mask=dissolve[:,:,di if di<3 else 3]
  amount=floats.get('_Amount',0)+custom1[0];border=max(.00001,floats.get('_BorderWidth',.01))
  fade=np.clip((mask-amount+border*(1-round(amount+.5)))/border,0,1)
  color=main*a*maincolor*color0*grad(entry.get('colorOverLife'),p)
  color[:,:,:3]*=2
  color[:,:,3]*=fade*floats.get('_Opacity',1)
  if t>=life:color[:,:,:]=0
  tile=Image.fromarray(np.uint8(np.clip(color*255,0,255)))
  atlas.paste(tile,((frame%columns)*w,(frame//columns)*h))
 name=f"baked_{material['m_Name'].lower()}.png";atlas.save(target/name,optimize=True)
 chain=[];cur=go
 while cur in transforms:
  tr=transforms[cur];chain.append(tr);cur=ref(tree.get(ref(tr.get('m_Father')),{}).get('m_GameObject'))
 scale={a:size['startSize'+('' if a=='x' else a.upper())]['scalar'] for a in 'xyz'}
 particle={'m_LocalPosition':dict(x=0,y=0,z=0),'m_LocalRotation':dict(x=0,y=0,z=0,w=1),'m_LocalScale':scale}
 geometry=mesh_geometry(tree[ref(renderer['m_Mesh'])],[particle]+chain[:-1])
 entry.update(kind='mesh',geometry=geometry,position=[0,0],scale=[1,1],rotation=0)
 entry['material'].update(main=name,tint=[1]*4,mainColor=[1]*4,frames=dict(count=count,columns=columns,fps=fps,width=w,height=h))
 print(entry['name'],name,'frames',count,'life',life,'position range',[(min(p[i] for p in geometry['positions']),max(p[i] for p in geometry['positions'])) for i in range(3)])

# 将普通粒子按预制体的三维父变换投影；FxEmitterSim 将尺寸换算为 100 像素/单位。
from avg_fx_mesh import transform_point
for entry in data['emitters']:
 if entry['kind'] != 'particle':continue
 renderer=renderers[entry['name']];cur=ref(renderer['m_GameObject']);chain=[]
 while cur in transforms:
  tr=transforms[cur];chain.append(tr);cur=ref(tree.get(ref(tr.get('m_Father')),{}).get('m_GameObject'))
 chain=chain[:-1];origin=transform_point([0,0,0],chain)
 basis=[[(v-origin[j])/100 for j,v in enumerate(transform_point(p,chain))] for p in ([1,0,0],[0,1,0])]
 entry.update(position=[0,0],scale=[1,1],rotation=0,transform3D=[origin,*basis],alignment=renderer.get('m_RenderAlignment',0),pivot=[renderer.get('m_Pivot',{}).get(c,0) for c in 'xy'],lengthScale=renderer.get('m_LengthScale',1))
data['isLoop']=False
(target/'fx.json').write_text(dumps(data),encoding='utf8')