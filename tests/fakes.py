"""In-memory async fakes for PyMongo collections.

These exercise the real service and endpoint code without a live MongoDB.
Filter matching covers equality and ``$in`` (including overlap for array
fields); ``$near``/``$geoWithin``/``$geoNear`` match every document without
real geospatial semantics, which still need a live database to verify.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from bson import ObjectId


def _clause_matches(doc: dict, field: str, expected: Any) -> bool:
    if isinstance(expected, dict) and any(key.startswith("$") for key in expected):
        if "$in" in expected:
            actual = doc.get(field)
            if isinstance(actual, list):
                return any(item in expected["$in"] for item in actual)
            return actual in expected["$in"]
        if "$near" in expected or "$geoWithin" in expected:
            return True
        raise NotImplementedError(f"unsupported operator in fake matcher: {expected}")
    return doc.get(field) == expected


def _matches(doc: dict, query: dict) -> bool:
    return all(_clause_matches(doc, field, expected) for field, expected in query.items())


class FakeCursor:
    def __init__(self, docs: list[dict]):
        self._docs = docs
        self._limit: int | None = None

    def limit(self, n: int) -> FakeCursor:
        self._limit = n
        return self

    async def __aiter__(self):  # type: ignore[misc]
        docs = self._docs if self._limit is None else self._docs[: self._limit]
        for doc in docs:
            yield doc


class FakeCollection:
    def __init__(self):
        self.docs: dict[ObjectId, dict] = {}
        self.indexes: list[tuple] = []

    async def insert_one(self, doc: dict) -> SimpleNamespace:
        inserted_id = doc.get("_id", ObjectId())
        stored = {**doc, "_id": inserted_id}
        self.docs[inserted_id] = stored
        return SimpleNamespace(inserted_id=inserted_id)

    async def find_one(self, query: dict) -> dict | None:
        for doc in self.docs.values():
            if _matches(doc, query):
                return doc
        return None

    def find(self, query: dict) -> FakeCursor:
        return FakeCursor([doc for doc in self.docs.values() if _matches(doc, query)])

    @staticmethod
    def _apply_update(doc: dict, update: dict) -> None:
        doc.update(update.get("$set", {}))
        for field, amount in update.get("$inc", {}).items():
            doc[field] = doc.get(field, 0) + amount

    async def update_one(self, query: dict, update: dict, upsert: bool = False) -> SimpleNamespace:
        for doc in self.docs.values():
            if _matches(doc, query):
                self._apply_update(doc, update)
                return SimpleNamespace(matched_count=1, modified_count=1, upserted_id=None)
        if upsert:
            stored = {key: value for key, value in query.items() if not isinstance(value, dict)}
            stored.update(update.get("$set", {}))
            stored["_id"] = ObjectId()
            self.docs[stored["_id"]] = stored
            return SimpleNamespace(matched_count=0, modified_count=0, upserted_id=stored["_id"])
        return SimpleNamespace(matched_count=0, modified_count=0, upserted_id=None)

    async def delete_one(self, query: dict) -> SimpleNamespace:
        for key, doc in list(self.docs.items()):
            if _matches(doc, query):
                del self.docs[key]
                return SimpleNamespace(deleted_count=1)
        return SimpleNamespace(deleted_count=0)

    async def update_many(self, query: dict, update: dict) -> SimpleNamespace:
        matched = 0
        for doc in self.docs.values():
            if _matches(doc, query):
                self._apply_update(doc, update)
                matched += 1
        return SimpleNamespace(matched_count=matched, modified_count=matched)

    async def aggregate(self, pipeline: list[dict]) -> FakeCursor:
        docs = list(self.docs.values())
        for stage in pipeline:
            if "$geoNear" in stage:
                query = stage["$geoNear"].get("query", {})
                docs = [doc for doc in docs if _matches(doc, query)]
            elif "$limit" in stage:
                docs = docs[: stage["$limit"]]
            else:
                raise NotImplementedError(f"unsupported fake aggregate stage: {stage}")
        return FakeCursor(docs)

    async def find_one_and_update(self, query: dict, update: dict, **kwargs: Any) -> dict | None:
        _ = kwargs
        for doc in self.docs.values():
            if _matches(doc, query):
                doc.update(update.get("$set", {}))
                return doc
        return None

    async def create_index(self, *args: Any, **kwargs: Any) -> str:
        _ = kwargs
        self.indexes.append(args)
        return "fake_index"


class FakeDatabase:
    def __init__(self):
        self._collections: dict[str, FakeCollection] = {}

    def __getitem__(self, name: str) -> FakeCollection:
        return self._collections.setdefault(name, FakeCollection())
