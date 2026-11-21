"""The layout of the database package.

``Database`` is composed from one part per domain (``app/database/<domain>.py``)
over a shared core (``app/database/core.py``). These rules keep that shape:

- a member of ``Database`` is defined in exactly one class;
- a part's code uses only its own members and the core's, and the core only
  its own (composed into one class, a reach into another part would still
  run, and bring back the dependency the split removed);
- a part's module imports no other part's module and not ``database.py``,
  and neither does the core;
- no module of the package imports ``app.services`` at its top (the services
  import the database; the imports that remain are inside functions);
- the leaves under ``app/core`` import nothing from ``app.database`` or
  ``app.services``;
- the log names the split kept on purpose stay as they were.
"""

import ast
from pathlib import Path

from app.database.core import DatabaseCore
from app.database.database import Database

APP = Path(__file__).resolve().parents[1] / "app"

PART_CLASSES = [cls for cls in Database.__mro__[1:] if cls not in (DatabaseCore, object)]
PART_MODULES = {cls.__module__ for cls in PART_CLASSES}


def _outside_functions(node):
    """Every node that runs when the module is imported (also inside ``if``,
    ``try`` and class bodies), not the bodies of functions."""
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            continue
        yield child
        yield from _outside_functions(child)


def _imports(path: Path, *, top_level_only: bool) -> set[str]:
    """The modules ``path`` imports, as absolute names (``from .x import y`` in
    ``app/database`` reads ``app.database.x`` and ``app.database.x.y``)."""
    tree = ast.parse(path.read_text())
    package = ".".join(path.relative_to(APP.parent).with_suffix("").parts[:-1])
    nodes = _outside_functions(tree) if top_level_only else ast.walk(tree)
    found = set()
    for node in nodes:
        if isinstance(node, ast.Import):
            found.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            base = package.rsplit(".", node.level - 1)[0] if node.level else ""
            module = ".".join(part for part in (base, node.module) if part)
            found.add(module)
            found.update(f"{module}.{alias.name}" for alias in node.names)
    return found


def test_database_is_composed_from_eleven_parts_over_the_core():
    assert len(PART_CLASSES) == 11
    assert all(issubclass(cls, DatabaseCore) for cls in PART_CLASSES)
    assert all(cls.__bases__ == (DatabaseCore,) for cls in PART_CLASSES)
    assert all(module.startswith("app.database.") for module in PART_MODULES)


def test_every_member_is_defined_in_exactly_one_class():
    defined: dict[str, list[str]] = {}
    for cls in (Database, *PART_CLASSES, DatabaseCore):
        for name in vars(cls):
            if name.startswith("__") and name != "__init__":
                continue
            defined.setdefault(name, []).append(cls.__name__)

    assert {name: classes for name, classes in defined.items() if len(classes) > 1} == {}


def test_a_part_imports_no_other_part_and_not_the_composed_class():
    for module in sorted(PART_MODULES):
        path = APP / "database" / (module.rsplit(".", 1)[1] + ".py")
        imported = _imports(path, top_level_only=False)
        others = (PART_MODULES - {module}) | {"app.database.database"}

        assert imported & others == set(), module
        assert not any(name == "app.database" for name in imported), module


def test_the_core_imports_no_part_and_not_the_composed_class():
    imported = _imports(APP / "database" / "core.py", top_level_only=False)

    assert imported & (PART_MODULES | {"app.database.database", "app.database"}) == set()


def test_no_module_of_the_package_imports_the_services_at_its_top():
    for path in sorted((APP / "database").glob("*.py")):
        imported = _imports(path, top_level_only=True)

        assert not any(name.startswith("app.services") for name in imported), path.name


def test_the_core_leaves_import_nothing_from_the_database_or_the_services():
    for path in sorted((APP / "core").glob("*.py")):
        imported = _imports(path, top_level_only=False)

        assert not any(
            name.startswith(("app.database", "app.services")) for name in imported
        ), path.name


# What ``DatabaseCore.__init__`` sets on the object, beside the class members.
_CORE_INSTANCE_ATTRIBUTES = {"context", "_held"}


def _members_used(path: Path, class_name: str) -> tuple[set[str], set[str]]:
    """In the body of ``class_name`` in ``path``: every attribute read on
    ``self``, ``cls``, the class's own name or ``DatabaseCore``, and every
    other part's class name the body mentions."""
    tree = ast.parse(path.read_text())
    [body] = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == class_name]
    owners = {"self", "cls", class_name, "DatabaseCore"}
    other_parts = {cls.__name__ for cls in PART_CLASSES} - {class_name}
    used, mentioned = set(), set()
    for node in ast.walk(body):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in owners:
            used.add(node.attr)
        elif isinstance(node, ast.Name) and node.id in other_parts:
            mentioned.add(node.id)
    return used, mentioned


def test_a_part_uses_only_its_own_members_and_the_cores():
    """A part reaching into another part's member would still work, because
    they are composed into one class, and would bring back the hidden
    dependency the split removed."""
    core = set(dir(DatabaseCore)) | _CORE_INSTANCE_ATTRIBUTES
    for cls in PART_CLASSES:
        path = APP / "database" / (cls.__module__.rsplit(".", 1)[1] + ".py")
        used, mentioned = _members_used(path, cls.__name__)

        assert used - set(vars(cls)) - core == set(), cls.__name__
        assert mentioned == set(), cls.__name__


def test_the_core_uses_only_its_own_members():
    used, mentioned = _members_used(APP / "database" / "core.py", "DatabaseCore")

    assert used - set(dir(DatabaseCore)) - _CORE_INSTANCE_ATTRIBUTES == set()
    assert mentioned == set()



def test_the_log_names_are_the_ones_from_before_the_split():
    """An operator filters on these names; the split kept them on purpose.
    The core logs nothing since the durable point's own flush went (audit
    AU3-01: its one line was that flush's warning), so it has no logger; one
    added there takes the name ``app.database.database``, as the identity
    part's has."""
    import app.core.job_runtime
    import app.database.core
    import app.database.identity

    assert not hasattr(app.database.core, "logger")
    assert app.database.identity.logger.name == "app.database.database"
    assert app.core.job_runtime.logger.name == "app.services.job_runtime"
