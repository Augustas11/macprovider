AC-30 openai-python strict json_schema fixture.

Pinned SDK: openai==2.44.0.

Logical model:

```python
class Person(BaseModel):
    name: str
    age: float
```

The fixture uses `float` so the emitted schema type is `number`, matching the Vercel Zod fixture.
