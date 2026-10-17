"""Fail the CAD image build if shared Python/native geometry dependencies break."""
import importlib
import importlib.metadata
import sys


def main():
    packages = {
        "Pillow": "PIL",
        "cadquery": "cadquery",
        "cadquery-massembly": "cadquery_massembly",
        "numpy": "numpy",
        "scipy": "scipy",
        "trimesh": "trimesh",
        "manifold3d": "manifold3d",
        "rtree": "rtree",
        "networkx": "networkx",
    }
    modules = {
        package: importlib.import_module(module)
        for package, module in packages.items()
    }

    solid = modules["manifold3d"].Manifold.cube((2, 2, 2))
    if abs(solid.volume() - 8) > 1e-9:
        raise RuntimeError("Manifold native geometry check failed")

    index = modules["rtree"].index.Index()
    try:
        index.insert(1, (0, 0, 1, 1))
        if list(index.intersection((0.25, 0.25, 0.75, 0.75))) != [1]:
            raise RuntimeError("Rtree native spatial index check failed")
    finally:
        index.close()

    mesh = modules["trimesh"].creation.box(extents=(2, 2, 2))
    if len(mesh.split()) != 1 or not mesh.contains([[0, 0, 0]])[0]:
        raise RuntimeError("Trimesh component/spatial dependency check failed")

    print(f"CAD interpreter: {sys.executable} ({sys.version.split()[0]})")
    for package in packages:
        print(f"{package}=={importlib.metadata.version(package)}")
    print("CAD imports, native geometry and spatial checks passed")


if __name__ == "__main__":
    main()
