"""Reference chat-template rendering for GLM-5.3-Flash (epic #2029). Lab only.

Renders every case of scripts/tests/fixtures/glm53-chat-template/cases.json with
transformers' apply_chat_template (Jinja2, CPU only, no model load) and writes
the rendered text and token ids that GLM5NextChatTemplateTests compares the
provider's swift-jinja rendering against. Run in a venv with transformers:

    python glm53_template_reference.py <artifact dir> cases.json reference.json

The fixture was generated with transformers 5.17.0 and Jinja2 3.1.6 on
Jundot/GLM-5.3-Flash-oQ4e-mtp @ 36defc50.
"""
import json, sys
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained(sys.argv[1])
out = []
for case in json.load(open(sys.argv[2])):
    kw = dict(case.get("context", {}))
    text = tok.apply_chat_template(case["messages"], tools=case.get("tools"), add_generation_prompt=True, tokenize=False, **kw)
    ids = tok.apply_chat_template(case["messages"], tools=case.get("tools"), add_generation_prompt=True, tokenize=True, **kw)
    ids = ids["input_ids"] if hasattr(ids, "keys") else ids
    out.append({"name": case["name"], "text": text, "ids": list(ids)})
json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
print(len(out))
