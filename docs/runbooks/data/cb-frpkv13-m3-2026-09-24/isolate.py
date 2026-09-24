# Isolation matrix for ragged batched decode correctness. Prints, per scenario,
# which rows match their serial greedy output exactly (content not recorded).
import http.client, json, threading, time, uuid
PORT=18080
P=["What is the capital of France? Answer in one sentence.","List the first ten prime numbers separated by commas.","Write a Python function that returns the factorial of n.","Name the planets of the solar system in order from the sun."]
def gen(p, rid, mt=60):
    c=http.client.HTTPConnection("127.0.0.1",PORT,timeout=600); h={"Content-Type":"application/json"}
    if rid: h["X-Request-ID"]=rid
    c.request("POST","/v1/chat/completions",json.dumps({"model":"qwen3-coder-30b-a3b-instruct","messages":[{"role":"user","content":p}],"max_tokens":mt,"temperature":0}),h)
    j=json.loads(c.getresponse().read()); return (j["choices"][0]["message"]["content"], j["usage"]["prompt_tokens"]) if "choices" in j else (None, None)
serial={p: gen(p,None) for p in P}
def scenario(name, prompts, stagger=0.0):
    out=[None]*len(prompts)
    def run(i): out[i]=gen(prompts[i],"iso-"+uuid.uuid4().hex[:8])
    ts=[threading.Thread(target=run,args=(i,)) for i in range(len(prompts))]
    for t in ts:
        t.start(); time.sleep(stagger)
    [t.join() for t in ts]
    res=[(serial[p][1], out[i][0]==serial[p][0]) for i,p in enumerate(prompts)]
    print(json.dumps({"scenario":name,"rows(prompt_tokens,exact)":res}))
scenario("equal_len_x4_same_prompt",[P[0]]*4)
scenario("ragged_x3",P[:3])
scenario("ragged_x4_simultaneous",P)
scenario("ragged_x4_staggered_0.5s",P,0.5)
scenario("ragged_x2_long_short",[P[1],P[3]])
