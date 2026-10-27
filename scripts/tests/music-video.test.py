#!/usr/bin/env python3
"""music-video (its own plugin): offline checks, no API is called and no key is needed. new_project.sh
scaffolds a project (a fake npm stands in for the install) with the fonts and their license, and a rerun keeps
what the user edited; gen_music.py refuses a malformed flag before it spends anything, sends each engine's
default model and only el1 the section-duration flag, and every model is overridable from the environment.

  python3 scripts/tests/music-video.test.py
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import warnings

sys.dont_write_bytecode = True  # keep __pycache__ out of the skill directory
try:
    from PIL import Image
except ImportError:  # the contact-sheet checks need Pillow, as the script does
    Image = None
SKILL = Path(__file__).resolve().parents[2] / "plugins/music-video/skills/music-video"
SCRIPTS = SKILL / "scripts"


def load(name, project, **env):
    """Import scripts/<name>.py fresh, for a project, with extra environment variables."""
    loader = importlib.machinery.SourceFileLoader(f"mv_{name}", str(SCRIPTS / f"{name}.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, {"MV_PROJECT": str(project), **env}):
        loader.exec_module(module)
    return module


class MusicVideoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="music-video-test-")
        root = Path(cls.temp.name).resolve()
        (root / "bin").mkdir()
        fake_npm = root / "bin" / "npm"
        fake_npm.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD $*" >> "$FAKE_NPM_LOG"\n')
        fake_npm.chmod(0o755)
        cls.npm_log = root / "npm.log"
        cls.env = {**os.environ, "PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}",
                   "FAKE_NPM_LOG": str(cls.npm_log)}
        for key in ("ELEVENLABS_API_KEY", "GOOGLE_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "MESHY_API_KEY"):
            cls.env.pop(key, None)
        cls.project = root / "song"
        cls.first = subprocess.run(["bash", str(SCRIPTS / "new_project.sh"), str(cls.project)], env=cls.env,
                                   capture_output=True, text=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        # The scripts write with open(...).write(...), which CPython closes at once; not a finding here.
        warnings.simplefilter("ignore", ResourceWarning)

    def test_scaffold_lays_out_a_project(self):
        self.assertEqual(self.first.returncode, 0, self.first.stderr)
        for rel in ("lyrics.json", "cues.json", "images/prompts.json", "clips/jobs.json", "music", "sfx",
                    "build/studio.html", "build/render.mjs", "build/package.json", "build/src/core.js",
                    "build/src/shots/example.js", "build/fonts/fonts.css", "build/out"):
            self.assertTrue((self.project / rel).exists(), rel)
        self.assertIn(f"{self.project / 'build'} install", self.npm_log.read_text())

    def test_the_fonts_travel_with_their_license(self):
        fonts = self.project / "build/fonts"
        self.assertEqual(len(list(fonts.glob("*.woff2"))), 6)
        license_text = (fonts / "OFL.txt").read_text()
        self.assertIn("SIL OPEN FONT LICENSE Version 1.1", license_text)
        for family in ("Bricolage Grotesque", "Caveat", "Instrument Serif", "Inter", "JetBrains Mono"):
            self.assertIn(f"The {family} Project Authors", license_text)

    def test_a_rerun_keeps_what_the_user_changed(self):
        lyrics, shot = self.project / "lyrics.json", self.project / "build/src/shots/example.js"
        lyrics.write_text('{"title": "mine"}\n')
        shot.write_text("// mine\n")
        (self.project / "build/src/core.js").unlink()
        again = subprocess.run(["bash", str(SCRIPTS / "new_project.sh"), str(self.project)], env=self.env,
                               capture_output=True, text=True, timeout=60)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(lyrics.read_text(), '{"title": "mine"}\n')
        self.assertEqual(shot.read_text(), "// mine\n")
        self.assertTrue((self.project / "build/src/core.js").exists(), "a missing template file is restored")
        lyrics.write_text((SKILL / "template/lyrics.example.json").read_text())

    def test_a_malformed_flag_is_refused_before_any_call(self):
        out = subprocess.run([sys.executable, "-B", str(SCRIPTS / "gen_music.py"), "el1", "--tag", "b"],
                             env={**self.env, "MV_PROJECT": str(self.project)}, capture_output=True, text=True,
                             timeout=60)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("unknown arguments", out.stderr)
        self.assertFalse((self.project / "music/el1_a.mp3").exists())

    def test_each_engine_sends_its_model_and_only_el1_holds_section_durations(self):
        gen = load("gen_music", self.project)
        sent = []

        def fake_post(url, body, headers, timeout=900):
            sent.append((url, body))
            return 200, "audio/mpeg", b"mp3", None

        with patch.object(gen, "post", side_effect=fake_post), \
                patch.dict(os.environ, {"ELEVENLABS_API_KEY": "test-key"}):
            os.makedirs(gen.OUT, exist_ok=True)
            gen.run_el("el1", gen.el1_plan(), "el1_t")
            gen.run_el("el25", gen.el25_plan(), "el25_t")
        (el1_url, el1), (_, el25) = sent
        self.assertIn("api.elevenlabs.io/v1/music", el1_url)
        self.assertEqual((el1["model_id"], el1.get("respect_sections_durations")), ("music_v1", True))
        self.assertEqual(el25["model_id"], "music_v2_5")
        self.assertNotIn("respect_sections_durations", el25)
        self.assertEqual(len(el1["composition_plan"]["sections"]), 3)

    def test_lyria_sends_its_model_and_saves_audio_and_lyric_sheet(self):
        gen = load("gen_music", self.project, LYRIA_MODEL="lyria-test")
        reply = {"outputs": [{"type": "text", "text": "[0.0:] line"},
                             {"type": "audio", "data": "bXAz"}]}  # base64 of "mp3"
        with patch.object(gen, "post", return_value=(200, "application/json", json.dumps(reply).encode(), None)) as post, \
                patch.dict(os.environ, {"GOOGLE_API_KEY": "test-key"}):
            os.makedirs(gen.OUT, exist_ok=True)
            msg = gen.run_lyria("lyria_t")
        self.assertEqual(post.call_args.args[1]["model"], "lyria-test")
        self.assertIn("3 bytes", msg)
        self.assertEqual((self.project / "music/lyria_t.txt").read_text(), "[0.0:] line")

    def test_every_model_default_can_be_overridden(self):
        gen = load("gen_music", self.project, EL1_MODEL="el1-x", EL25_MODEL="el25-x")
        self.assertEqual(gen.EL_MODELS, {"el1": "el1-x", "el25": "el25-x"})
        self.assertEqual(load("gen_images", self.project, IMAGE_MODEL="img-x").MODEL, "img-x")
        self.assertEqual(load("gen_videos", self.project, VIDEO_MODEL="vid-x").MODEL, "vid-x")
        self.assertEqual(load("watch", self.project, WATCH_MODEL="watch-x", GOOGLE_API_KEY="k").MODEL, "watch-x")

    def image_project(self, name):
        """A project with an existing hero.png (the old design) and a scene that references it."""
        proj = Path(self.temp.name) / name
        (proj / "images").mkdir(parents=True)
        spec = {"style": "s", "night_style": "n", "surreal_style": "u", "size": "1024x1024",
                "images": [{"id": "hero", "prompt": "the hero"},
                           {"id": "scene", "prompt": "the hero on a lawn", "refs": ["hero"]}]}
        (proj / "images/prompts.json").write_text(json.dumps(spec))
        (proj / "images/hero.png").write_bytes(b"old hero")
        return proj

    def regenerate(self, proj, hero_ok):
        """Run gen_images.py --force with two workers and a fake generator; return what each item saw."""
        gen = load("gen_images", proj)
        seen = {}

        def fake_generate(item):
            if item["id"] == "hero":
                time.sleep(0.5)   # a slow paid generation, so a scene started alongside it would win the race
                if not hero_ok:
                    return False, "hero: FAILED"
            seen[item["id"]] = (proj / "images/hero.png").read_bytes()
            (proj / "images" / f"{item['id']}.png").write_bytes(f"new {item['id']}".encode())
            return True, f"{item['id']}: ok"

        with patch.object(gen, "generate", side_effect=fake_generate), \
                patch.object(sys, "argv", ["gen_images.py", "--force", "--workers=2"]):
            try:
                gen.main()
                exit_msg = None
            except SystemExit as e:
                exit_msg = str(e)
        return seen, exit_msg

    def test_a_reference_being_regenerated_finishes_before_its_dependents_start(self):
        proj = self.image_project("images-force")
        seen, exit_msg = self.regenerate(proj, hero_ok=True)
        self.assertIsNone(exit_msg)
        self.assertEqual(seen.get("scene"), b"new hero", "the scene was conditioned on the old hero")

    def test_a_reference_that_fails_to_regenerate_blocks_its_dependents(self):
        proj = self.image_project("images-hero-fails")
        seen, exit_msg = self.regenerate(proj, hero_ok=False)
        self.assertNotIn("scene", seen, "the scene was generated from the old hero")
        self.assertIn("scene", exit_msg or "")

    @unittest.skipUnless(Image, "Pillow not installed")
    def test_a_contact_sheet_renders_wherever_the_script_runs(self):
        work = Path(self.temp.name) / "sheet"
        (work / "out/frames").mkdir(parents=True)
        for n in (1, 31):
            Image.new("RGB", (64, 36), "navy").save(work / f"out/frames/f{n:05d}.jpg")
        out = subprocess.run([sys.executable, "-B", str(SCRIPTS / "sheet_frames.py"), "0", "1", "1", "sheet.jpg", "2", "120"],
                             cwd=work, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr[-400:])
        self.assertEqual(Image.open(work / "sheet.jpg").size, (240, 67))

    @unittest.skipUnless(Image, "Pillow not installed")
    def test_the_sheet_labels_fall_back_to_a_built_in_font(self):
        sheet = load("sheet_frames", self.project)
        font = sheet.label_font([str(Path(self.temp.name) / "no-such-font.ttf")])
        self.assertTrue(hasattr(font, "getbbox"), font)

    def test_documented_defaults_match_the_scripts(self):
        table = (SKILL / "references/pipeline.md").read_text()
        gen = load("gen_music", self.project)
        for default in (gen.LYRIA_MODEL, gen.EL_MODELS["el1"], gen.EL_MODELS["el25"],
                        load("gen_images", self.project).MODEL, load("gen_videos", self.project).MODEL,
                        load("watch", self.project, GOOGLE_API_KEY="k").MODEL):
            self.assertIn(f"`{default}`", table)
        score = (SCRIPTS / "score_song.py").read_text()
        for var, default in (("SCRIBE_MODEL", "scribe_v2"), ("WHISPER_MODEL", "whisper-1")):
            self.assertIn(f'os.environ.get("{var}", "{default}")', score)
            self.assertIn(f"| `{var}` | `{default}` |", table)
        self.assertIn('os.environ.get("LISTEN_MODEL", ', (SCRIPTS / "listen.py").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
