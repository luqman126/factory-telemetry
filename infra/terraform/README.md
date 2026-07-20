# Infrastructure as Code (IaC) — Terraform Staging Environment

Direktori ini berisi konfigurasi Terraform untuk melakukan *provisioning* lingkungan **Staging** yang aman dan terisolasi untuk proyek IoT Big Data.

---

## 📂 Struktur File

```text
infra/terraform/
├── environments/
│   └── staging.tfvars      # Variabel spesifik staging (VPC 10.1.x.x, instance t3.small)
├── .gitignore              # Mencegah state file dan credentials ter-commit ke Git
├── main.tf                 # Setup Provider AWS dan local state
├── variables.tf            # Definisi parameter input
├── outputs.tf              # Output koneksi (IP Publik, VPC ID, dll.) setelah deploy
├── network.tf              # VPC, Subnet (Public/Private), IGW, Route Table, S3 Endpoint
├── security.tf             # Security Groups (applayer, datalayer, worker) dengan rule dinamis
└── compute.tf              # EC2 instances, IAM role/profile, dan Elastic IP
```

---

## 🛠️ Prasyarat Sebelum Deploy

Sebelum menjalankan Terraform, pastikan Anda telah memenuhi langkah-langkah berikut:

1. **Instalasi Terraform & AWS CLI:**
   - Terraform (versi >= 1.5.0)
   - AWS CLI terkonfigurasi dengan kredensial AWS Anda (`aws configure`).

2. **EC2 Key Pair:**
   Pastikan Anda sudah memiliki EC2 Key Pair di AWS Console region `ap-southeast-1` (misalnya bernama `iot-bigdata-key`). Key pair ini dibutuhkan untuk mengakses SSH ke *server* yang baru dibuat.

3. **Cek File `environments/staging.tfvars`:**
   Buka file `environments/staging.tfvars` dan sesuaikan parameter berikut dengan nilai yang ada di akun AWS Anda:
   - `key_pair_name`: Nama Key Pair Anda.
   - `ami_id`: AMI base Amazon Linux 2023 di region Singapore.
   - `worker_ami_id`: AMI custom untuk Spark Worker (atau Anda dapat menggunakan AMI base yang sama untuk pengujian awal).

---

## 🚀 Langkah Deploy (Provisioning)

Jalankan perintah berikut di dalam direktori `infra/terraform/`:

### 1. Inisialisasi Terraform
Unduh provider AWS dan inisialisasi modul:
```bash
terraform init
```

### 2. Validasi Sintaks
Pastikan tidak ada kesalahan ketik atau logika dependensi pada file `.tf`:
```bash
terraform validate
```

### 3. Preview Rencana Perubahan (Plan)
Melihat daftar resource yang akan dibuat tanpa benar-benar memodifikasi AWS:
```bash
terraform plan -var-file="environments/staging.tfvars"
```

### 4. Eksekusi Pembangunan (Apply)
Terapkan perubahan ke AWS untuk membuat Staging environment. Ketik `yes` saat diminta konfirmasi:
```bash
terraform apply -var-file="environments/staging.tfvars"
```

Setelah proses selesai (sekitar 2-3 menit), Terraform akan menampilkan **Outputs** di terminal berupa IP Publik `applayer-1` yang baru, IP Privat database nodes, dan ID Security Groups yang dibutuhkan untuk setup lanjutan.

---

## 🧹 Cara Menghapus Infrastruktur (Destroy)

Jika Anda sudah selesai melakukan eksperimen dan ingin menghemat biaya AWS, Anda dapat menghapus seluruh infrastruktur Staging ini bersih tanpa sisa dengan satu perintah:

```bash
terraform destroy -var-file="environments/staging.tfvars"
```
*(Ketik `yes` untuk konfirmasi).*

---

## ⚠️ Catatan Keamanan & Isolasi

1. **VPC Terpisah:** Staging dideploy di VPC `10.1.0.0/16` sedangkan Production berada di `10.0.0.0/16`. Keduanya terisolasi penuh sehingga eksperimen di Staging tidak akan pernah bocor ke data Production.
2. **State Management:** State disimpan secara **lokal** pada file `terraform.tfstate`. Jangan menghapus file ini karena ia adalah satu-satunya ingatan Terraform terhadap resource yang dideploy di AWS. File ini sudah otomatis dimasukkan ke `.gitignore` agar tidak bocor ke publik.
