"""Build-time export only. No Python runtime is shipped with the native app."""
import json
from pathlib import Path
import sys
import torch
from silero_stress import load_accentor

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
accentor = load_accentor()
# load_accentor restores the original quantized embedding weights before export.
torch.jit.save(accentor.accentor.model, str(out / 'accentor.jit'))
torch.jit.save(accentor.homosolver.model, str(out / 'homosolver.jit'))
tokenizer = accentor.homosolver.tokenizer
patterns = {}
for word, pattern in accentor.homosolver.compiled_phrases.items():
    names = list(pattern.groupindex)
    modified = pattern.pattern
    for i, name in enumerate(names): modified = modified.replace('(?P<' + name + '>', '(?<v' + str(i) + '>')
    patterns[word] = {'pattern': modified, 'variants': [accentor.homosolver.__class__.__call__.__globals__['decapitalize_stress'](name) for name in names]}
(out / 'metadata.json').write_text(json.dumps(dict(
    version='silero-stress-1.5', vocab=tokenizer.vocab,
    cls=tokenizer.cls_token_id, sep=tokenizer.sep_token_id, pad=tokenizer.pad_token_id,
    unk=tokenizer.unk_token_id, homo_start=tokenizer.homo_start_id, homo_end=tokenizer.homo_end_id,
    never_split=list(tokenizer.never_split), homographs={k:sorted(v) for k,v in accentor.homosolver.homodict.items()},
    exceptions=accentor.accentor.exceptions, patterns=patterns), ensure_ascii=False))
print('Silero exported for native C++ execution, including exceptions, tokenizer and contextual homographs')
