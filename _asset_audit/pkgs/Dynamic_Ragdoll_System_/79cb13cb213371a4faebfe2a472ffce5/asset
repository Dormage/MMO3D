using UnityEngine;

namespace DynamicRagdoll
{
    public class HandsDrive : MonoBehaviour
    {
    public BOS bos;
    public RagdollManager ragdollManager;

    public Transform LH_Idle;
    public Transform LH_Side;
    public Transform LH_Front;
    public Transform LH_Back;
    public Transform RH_Idle;
    public Transform RH_Side;
    public Transform RH_Front;
    public Transform RH_Back;
    public Transform LeftHandTarget;
    public Transform RightHandTarget;
    public Transform Pelvis;

    [Range(0f, 1f)]
    public float leftSlide;

    [Range(0f, 1f)]
    public float rightSlide;

    [Range(0f, 1f)]
    public float frontSlide;

    [Range(0f, 1f)]
    public float backSlide;

    public AnimationCurve slideCurve = AnimationCurve.Linear(0f, 0f, 1f, 1f);

    private Vector3 centerOfMassPoint;
    private Vector3 bosToComOffset;

    private void OnEnable()
    {
        leftSlide = 0f;
        rightSlide = 0f;
        frontSlide = 0f;
        backSlide = 0f;
    }

    private void OnDisable()
    {
        // El hedeflerini idle pozuna geri al, aksi halde IK son hesaplanan
        // ofsette donuk kalır.
        if (LeftHandTarget != null && LH_Idle != null)
        {
            LeftHandTarget.position = LH_Idle.position;
            LeftHandTarget.rotation = LH_Idle.rotation;
        }

        if (RightHandTarget != null && RH_Idle != null)
        {
            RightHandTarget.position = RH_Idle.position;
            RightHandTarget.rotation = RH_Idle.rotation;
        }

        leftSlide = 0f;
        rightSlide = 0f;
        frontSlide = 0f;
        backSlide = 0f;
    }

    private void Update()
    {
        // BOS noktası ve kütle merkezi
        if (ragdollManager != null && ragdollManager.jointSpringList != null)
        {
            CalculateCenterOfMass();
        }

        if (bos != null)
        {
            CalculateBosToComOffset();
        }

        Drive();

        // El pozisyonları
        // Sol el: Side ve Front/Back blendlerinin ortalaması
        if (LeftHandTarget != null && LH_Idle != null && LH_Side != null)
        {
            Vector3 sidePos = Vector3.Lerp(LH_Idle.position, LH_Side.position, leftSlide);
            Quaternion sideRot = Quaternion.Lerp(LH_Idle.rotation, LH_Side.rotation, leftSlide);

            Vector3 frontBackPos = LH_Idle.position;
            Quaternion frontBackRot = LH_Idle.rotation;

            if (frontSlide > 0f && LH_Front != null)
            {
                frontBackPos = Vector3.Lerp(LH_Idle.position, LH_Front.position, frontSlide);
                frontBackRot = Quaternion.Lerp(LH_Idle.rotation, LH_Front.rotation, frontSlide);
            }
            else if (backSlide > 0f && LH_Back != null)
            {
                frontBackPos = Vector3.Lerp(LH_Idle.position, LH_Back.position, backSlide);
                frontBackRot = Quaternion.Lerp(LH_Idle.rotation, LH_Back.rotation, backSlide);
            }

            LeftHandTarget.position = (sidePos + frontBackPos) / 2f;
            LeftHandTarget.rotation = Quaternion.Lerp(sideRot, frontBackRot, 0.5f);
        }

        // Sağ el: Side ve Front/Back blendlerinin ortalaması
        if (RightHandTarget != null && RH_Idle != null && RH_Side != null)
        {
            Vector3 sidePos = Vector3.Lerp(RH_Idle.position, RH_Side.position, rightSlide);
            Quaternion sideRot = Quaternion.Lerp(RH_Idle.rotation, RH_Side.rotation, rightSlide);

            Vector3 frontBackPos = RH_Idle.position;
            Quaternion frontBackRot = RH_Idle.rotation;

            if (frontSlide > 0f && RH_Front != null)
            {
                frontBackPos = Vector3.Lerp(RH_Idle.position, RH_Front.position, frontSlide);
                frontBackRot = Quaternion.Lerp(RH_Idle.rotation, RH_Front.rotation, frontSlide);
            }
            else if (backSlide > 0f && RH_Back != null)
            {
                frontBackPos = Vector3.Lerp(RH_Idle.position, RH_Back.position, backSlide);
                frontBackRot = Quaternion.Lerp(RH_Idle.rotation, RH_Back.rotation, backSlide);
            }

            RightHandTarget.position = (sidePos + frontBackPos) / 2f;
            RightHandTarget.rotation = Quaternion.Lerp(sideRot, frontBackRot, 0.5f);
        }
    }

    private void CalculateCenterOfMass()
    {
        Vector3 sum = Vector3.zero;
        float totalMass = 0f;

        foreach (var jointInfo in ragdollManager.jointSpringList)
        {
            if (jointInfo.joint == null)
                continue;

            Rigidbody rb = jointInfo.joint.GetComponent<Rigidbody>();
            if (rb == null)
                continue;

            sum += rb.worldCenterOfMass * rb.mass;
            totalMass += rb.mass;
        }

        if (totalMass > 0f)
        {
            centerOfMassPoint = sum / totalMass;
        }
    }

    private void CalculateBosToComOffset()
    {
        Vector3 offset = centerOfMassPoint - bos.Bospoint;
        offset.y = 0f;
        bosToComOffset = offset;
    }

    private void Drive()
    {
        if (RH_Idle == null || Pelvis == null)
            return;

        Vector3 rhIdleToPelvis = RH_Idle.position - Pelvis.position;
        rhIdleToPelvis.y = 0f;

        Vector3 rhFrontToPelvis = RH_Front.position - Pelvis.position;
        rhFrontToPelvis.y = 0f;

        float SideDot = Vector3.Dot(rhIdleToPelvis, bosToComOffset);
        float SideMagnitude = Vector3.Project(bosToComOffset, rhIdleToPelvis).magnitude;

        float FrontDot = Vector3.Dot(rhFrontToPelvis, bosToComOffset);
        float FrontMagnitude = Vector3.Project(bosToComOffset, rhFrontToPelvis).magnitude;


        float smoothSpeed = 1f / 0.7f;

        if (SideDot < 0f)
        {
            rightSlide = slideCurve.Evaluate(SideMagnitude);
            leftSlide = Mathf.MoveTowards(leftSlide, 0f, smoothSpeed * Time.deltaTime);
        }
        else if (SideDot > 0f)
        {
            leftSlide = slideCurve.Evaluate(SideMagnitude);
            rightSlide = Mathf.MoveTowards(rightSlide, 0f, smoothSpeed * Time.deltaTime);
        }

        if (FrontDot < 0f)
        {
            frontSlide = slideCurve.Evaluate(FrontMagnitude);
            backSlide = 0;
        }
        else if (FrontDot > 0f)
        {
            backSlide = slideCurve.Evaluate(FrontMagnitude);
            frontSlide = 0;
        }
    }
}
}
