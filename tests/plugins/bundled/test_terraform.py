"""terraform: the language (colours, comments, indentation, F5), its snippets, the outline without terraform-ls,
terraform-ls and terraform fmt when they are installed, the settings — and .tfvars (a language of its own, with
terraform-ls too) and .hcl (the outline always, no Terraform server)"""
import os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, run_sh, start
from tplugins import check

SAMPLE = '''# a comment: resource "x" "notThis" {}
terraform {
  required_version = ">= 1.5"
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

/* resource "aws_s3_bucket" "nope" {} */
resource "aws_instance" "web" {
  ami = data.aws_ami.ubuntu.id
  tags = {
    Name = "web-${lookup(var.names, "web")}"
  }
  user_data = <<-EOT
    resource "fake" "inHeredoc" {}
  EOT
}

data "aws_ami" "ubuntu" {
  most_recent = true
}

locals {
  name   = "app"
  common = { team = "x" }
}

module "vpc" {
  source = "./vpc"
}

output "ip" {
  value = aws_instance.web.public_ip
}'''.split("\n")

TFVARS = '''region = "eu-west-1"
# names = { a = 1 }
tags = {
  team = "x"
}
count_of = 3'''.split("\n")

HCL = '''include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../modules//vpc"
}

inputs = {
  cidr = "10.0.0.0/16"
}'''.split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "terraform",
        {"name": "Terraform", "extensions": ["tf"], "lineComment": "#", "blockComment": ["/*", "*/"],
         "quotes": "\"", "nameChars": "-", "indentSize": 2, "dedent": "})]", "build": "terraform validate",
         "keywords": {"resource", "data", "variable", "output", "locals", "module", "provider", "terraform",
                      "dynamic", "for_each", "count"},
         "types": {"string", "number", "bool", "list", "map", "object"}, "constants": {"true", "false", "null"}},
        ["resource", "data", "variable", "output", "module", "locals", "provider"],
        SAMPLE,
        [("terraform", "section", 0), ("aws", "module", 0), ("region", "variable", 0),
         ("aws_instance.web", "struct", 0), ("aws_ami.ubuntu", "struct", 0), ("locals", "section", 0),
         ("name", "constant", 1), ("common", "constant", 1), ("vpc", "module", 0), ("ip", "property", 0)],
        ["terraform", "terraform-ls"],
        runs=[("main.tf", "terraform {}\n", {}, "terraform plan")],
        server=["terraform-ls", "serve"], formatter="terraform fmt -")

    tmp = tempfile.mkdtemp(prefix="ned-terraform-")
    try:
        h, ok, err = start(factory, [os.path.join(tmp, "none")], only_path=True)
        vs = (h.reg("language", id="terraform-vars") or {}).get("spec", {}) if ok else {}
        hs = (h.reg("language", id="hcl") or {}).get("spec", {}) if ok else {}
        check(tag + ".tfvars and .hcl: languages of their own, coloured and indented as Terraform; F5 on a .tfvars: "
              "terraform plan with it", vs.get("extensions") == ["tfvars"] and vs.get("name") == "Terraform variables"
              and hs.get("extensions") == ["hcl"] and hs.get("name") == "HCL" and vs.get("lineComment") == "#" and
              hs.get("blockComment") == ["/*", "*/"] and "resource" in hs.get("keywords", []) and
              vs.get("run") == "terraform plan -var-file=\"$file\"" and "run" not in hs, (vs, hs))
        got = {}
        for lang, sample in (("terraform-vars", TFVARS), ("hcl", HCL)):
            r = h.reg("symbols", lang=lang)
            if r:
                h.lines = sample
                v = (h.call(r["cb"], {"buf": 1}) or {}).get("value") or []
                got[lang] = [(s["name"], s["kind"], s["depth"]) for s in v]
        check(tag + "the outline of a .tfvars (its variables) and of an .hcl (blocks and attributes)",
              got.get("terraform-vars") == [("region", "variable", 0), ("tags", "variable", 0),
                                            ("count_of", "variable", 0)] and
              got.get("hcl") == [("root", "struct", 0), ("terraform", "section", 0), ("inputs", "variable", 0)], got)
        done(h)
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["terraform", "terraform-ls"])
        h, ok, err = start(factory, [fake], only_path=True)
        lv = h.reg("lsp", lang="terraform-vars") if ok else None
        check(tag + "terraform-ls installed: it for .tfvars too, none for .hcl (its outline the scan's); terraform fmt "
              "formats all three", ok and lv and lv["cmd"] == ["terraform-ls", "serve"] and
              h.reg("lsp", lang="hcl") is None and h.reg("symbols", lang="hcl") is not None and
              h.reg("symbols", lang="terraform-vars") is None and
              all((h.reg("formatter", lang=x) or {}).get("cmd") == "terraform fmt -"
                  for x in ("terraform", "terraform-vars", "hcl")), (err, lv))
        done(h)
        f = os.path.join(tmp, "env", "prod.tfvars")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("region = \"x\"\n")
        o = run_sh(ned_cmd(vs.get("run", ""), f, "/T"), os.path.dirname(f), [fake])
        check(tag + "F5 on a .tfvars: terraform plan -var-file=file",
              o.split("\n")[0] == "terraform plan -var-file=" + f, o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
